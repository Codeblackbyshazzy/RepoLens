#!/usr/bin/env bash
# Copyright 2025-2026 Bootstrap Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# RepoLens — `## Validation` block parser (issue #332).
#
# Lifts the free-form `## Validation` markdown block a finding carries (the
# block contract is defined by #317, authored by lens agents) into a structured
# JSON object. `parse_validation_block` reads a finding's markdown from a file
# path argument OR from stdin, isolates the `## Validation` section, extracts
# six named fields, and emits ONE JSON object on stdout (built entirely with
# jq) with exactly these keys:
#
#   attacker_source, missing_guard, sink_effect, preconditions,
#   proof_anchors, suggested_validation
#
# Five fields are strings ("" when absent); `proof_anchors` is a JSON array of
# strings ([] when absent). It tolerates both the template's bulleted em-dash
# form (`- field — value`, U+2014 separator, lib/template.sh:560) and the
# audit.md colon form (`field: value` / `- field: value`). It never crashes on
# a finding without a `## Validation` block — that case yields the all-empty
# object. The structured object is exactly the shape the ledger's `validation`
# SLOT stores; wiring it into the ledger builders is a separate slice and is
# out of scope here.
#
# This module also provides `classify_validation_status` (issue #334), the pure
# rule that maps a structured `validation` object onto a registry `status`
# (`new` / `needs-validation` / `likely-false-positive`) from two axes — anchor
# strength and the command class of `suggested_validation` (locally-runnable
# check vs external scanner). See the comment block above that function for the
# exact precedence.
#
# Pure: each function works from its arguments / stdin plus jq alone, depends on
# no globals, and is safe to source under `set -uo pipefail`. This module is
# sourceable; it defines functions plus two named constant command-class lists
# (used by the classifier) and has no top-level runtime side effects — no
# output, no file writes.

# _validation_ltrim <string>
#   Prints the string with leading whitespace removed. Pure string transform
#   (parameter-expansion only — no external process).
_validation_ltrim() {
  local s="$1"
  printf '%s' "${s#"${s%%[![:space:]]*}"}"
}

# _validation_trim <string>
#   Prints the string with leading and trailing whitespace removed.
_validation_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# _validation_extract_section
#   Reads a finding's full markdown from stdin and prints only the lines that
#   belong to the `## Validation` section: everything after the
#   `## Validation` heading up to (but not including) the next level-1/level-2
#   markdown heading, or EOF. Only the FIRST `## Validation` block is honored.
#   Prints nothing when no `## Validation` heading is present. The heading is
#   matched liberally (trailing whitespace / CR tolerated). Side effect: writes
#   to stdout.
_validation_extract_section() {
  local line in_section=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ $in_section -eq 0 ]]; then
      if [[ "$line" =~ ^##[[:space:]]+Validation[[:space:]]*$ ]]; then
        in_section=1
      fi
      continue
    fi
    # A new top-level (#) or second-level (##) heading ends the section.
    if [[ "$line" =~ ^#{1,2}[[:space:]] ]]; then
      break
    fi
    printf '%s\n' "$line"
  done
}

# _validation_extract_field <field-name>
#   Reads `## Validation` section lines from stdin and prints the value of the
#   first line that declares <field-name>. Tolerates a leading list marker
#   (`-`, `*`, `+`), bold wrapping (`**field**`), and a separator of `:`,
#   em-dash (U+2014), en-dash (U+2013), or hyphen between the field name and
#   its value. Only the single separator immediately after the field name is
#   stripped — separators inside the value (paths like `lib/x.sh:42`, flags like
#   `grep -n`, em-dashes in prose) are preserved. Prints nothing (empty value)
#   when the field is not present. Side effect: writes to stdout.
_validation_extract_field() {
  local field="$1" line stripped rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    stripped="$(_validation_ltrim "$line")"
    # Strip a single leading list marker plus the whitespace after it.
    case "$stripped" in
      [-*+]\ *)
        stripped="${stripped#[-*+]}"
        stripped="$(_validation_ltrim "$stripped")"
        ;;
    esac
    # Strip a bold marker that opens before the field name (`**field`).
    stripped="${stripped#\*\*}"
    # The line must begin with the field name.
    case "$stripped" in
      "$field"*) ;;
      *) continue ;;
    esac
    rest="${stripped#"$field"}"
    # Strip a bold marker that closes after the field name (`field**`).
    rest="${rest#\*\*}"
    rest="$(_validation_ltrim "$rest")"
    # The first non-space after the field name must be a separator; otherwise
    # this is a different field whose name merely starts with <field-name>.
    case "$rest" in
      :*)  rest="${rest#:}" ;;
      —*)  rest="${rest#—}" ;;   # U+2014 EM DASH (template separator)
      –*)  rest="${rest#–}" ;;   # U+2013 EN DASH
      -*)  rest="${rest#-}" ;;
      *)   continue ;;
    esac
    # Strip a bold marker that closes after the separator (`**field:**`).
    rest="${rest#\*\*}"
    rest="$(_validation_ltrim "$rest")"
    printf '%s' "$rest"
    return 0
  done
}

# parse_validation_block [<finding-markdown-path>]
#   Reads a finding's markdown from <finding-markdown-path>, or from stdin when
#   no path (or "-") is given. A given-but-nonexistent path yields the
#   all-empty object rather than blocking on stdin. Isolates the
#   `## Validation` section, extracts the six contract fields, and emits ONE
#   JSON object on stdout (keys in issue order). String fields default to "";
#   proof_anchors is a JSON array of trimmed, non-empty strings (comma-split
#   from the field's inline value — a documented choice; per-anchor format
#   validation is #345's concern) and defaults to []. All values are emitted
#   via jq --arg/--argjson so quotes, `$(...)`, backticks, backslashes, etc.
#   cannot break the JSON or be interpreted. Never crashes on missing input.
#   Side effect: writes one JSON object to stdout.
parse_validation_block() {
  local src="${1:-}" content=""
  if [[ -z "$src" || "$src" == "-" ]]; then
    content="$(cat)"
  elif [[ -f "$src" ]]; then
    content="$(cat "$src")"
  else
    content=""
  fi

  local section
  section="$(printf '%s\n' "$content" | _validation_extract_section)"

  local attacker_source missing_guard sink_effect preconditions \
    suggested_validation proof_raw
  attacker_source="$(printf '%s\n' "$section" | _validation_extract_field attacker_source)"
  missing_guard="$(printf '%s\n' "$section" | _validation_extract_field missing_guard)"
  sink_effect="$(printf '%s\n' "$section" | _validation_extract_field sink_effect)"
  preconditions="$(printf '%s\n' "$section" | _validation_extract_field preconditions)"
  suggested_validation="$(printf '%s\n' "$section" | _validation_extract_field suggested_validation)"
  proof_raw="$(printf '%s\n' "$section" | _validation_extract_field proof_anchors)"

  # Normalize proof_anchors to a JSON array of trimmed, non-empty strings.
  # jq owns the splitting/trimming so element values are escaped safely.
  local proof_json
  proof_json="$(jq -cn --arg raw "$proof_raw" \
    '$raw | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))')"

  jq -n \
    --arg attacker_source "$attacker_source" \
    --arg missing_guard "$missing_guard" \
    --arg sink_effect "$sink_effect" \
    --arg preconditions "$preconditions" \
    --arg suggested_validation "$suggested_validation" \
    --argjson proof_anchors "$proof_json" \
    '{
      attacker_source: $attacker_source,
      missing_guard: $missing_guard,
      sink_effect: $sink_effect,
      preconditions: $preconditions,
      proof_anchors: $proof_anchors,
      suggested_validation: $suggested_validation
    }'
}

# ---------------------------------------------------------------------------
# Validation `status` classifier (issue #334)
# ---------------------------------------------------------------------------

# VALIDATION_LOCAL_CMDS
#   Allowlist of command tokens that mark a `suggested_validation` as a LOCAL,
#   self-contained check the audit host can run without any external service.
#   Matched against the command's FIRST token only (case-insensitive). One named
#   array so adding a tool is a one-line edit (AC). `curl` is intentionally NOT
#   listed here — it is local only against localhost / 127.0.0.1 and is handled
#   as a special case in `_validation_command_class`.
VALIDATION_LOCAL_CMDS=(
  grep rg test '[' bash sh cat ls find jq head tail wc diff awk sed
)

# VALIDATION_SCANNER_KEYWORDS
#   Denylist of external-scanner signals. Matched as a SUBSTRING anywhere in the
#   command (case-insensitive) so both bare tool names (`semgrep ...`) and the
#   prose form (`needs external scanner — npm audit`) are caught. The literal
#   phrase `external scanner` is included so this classifier is a SUPERSET of the
#   existing repo convention (artifacts.sh / human_review.sh / audit.md) and the
#   three consumers cannot drift. One named array so adding a scanner is a
#   one-line edit (AC).
VALIDATION_SCANNER_KEYWORDS=(
  'external scanner'
  semgrep trivy snyk bandit gitleaks trufflehog
  'npm audit' 'yarn audit' 'pnpm audit'
  'pip-audit' 'pip audit'
  'cargo audit'
  osv-scanner grype checkov tfsec dependency-check
)

# _validation_command_class <command-string>
#   Classifies a `suggested_validation` command string into exactly one of:
#     local   — first token is in VALIDATION_LOCAL_CMDS (or a curl against
#               localhost / 127.0.0.1).
#     scanner — references an external scanner (a VALIDATION_SCANNER_KEYWORDS
#               substring).
#     none    — empty / whitespace-only command (nothing to run).
#     unknown — a non-empty command that is neither local nor a known scanner.
#   The allowlist (first-token) is evaluated BEFORE the scanner denylist
#   (substring), so a genuinely local command that merely mentions a scanner name
#   as an argument — `grep -rn "semgrep" .` — classifies as `local`, not
#   `scanner`. The command string is treated purely as data (string ops only);
#   it is never evaluated by the shell. Side effect: writes the class to stdout.
#
#   Known limitation (accepted, per issue): classification keys off the first
#   token, so a wrapper like `bash -c 'semgrep ...'` classifies as `local`. Deep
#   argument parsing is out of scope and brittle.
_validation_command_class() {
  local cmd first lower tok kw
  cmd="$(_validation_trim "$1")"
  if [[ -z "$cmd" ]]; then
    printf 'none'
    return 0
  fi

  lower="${cmd,,}"
  first="${cmd%%[[:space:]]*}"
  first="${first,,}"

  if [[ "$first" == "curl" ]]; then
    # curl is a LOCAL check only when it targets the loopback host; a remote
    # fetch is not locally validatable and falls through to the scanner/unknown
    # determination below.
    if [[ "$lower" == *localhost* || "$lower" == *127.0.0.1* ]]; then
      printf 'local'
      return 0
    fi
  else
    for tok in "${VALIDATION_LOCAL_CMDS[@]}"; do
      # RHS quoted -> literal compare (so `[` is not read as a glob bracket).
      if [[ "$first" == "${tok,,}" ]]; then
        printf 'local'
        return 0
      fi
    done
  fi

  for kw in "${VALIDATION_SCANNER_KEYWORDS[@]}"; do
    if [[ "$lower" == *"${kw,,}"* ]]; then
      printf 'scanner'
      return 0
    fi
  done

  printf 'unknown'
}

# classify_validation_status <validation_json>
#   Pure rule that maps a structured `validation` object (the 6-key object
#   `parse_validation_block` emits — this function reads only two of its keys)
#   onto a registry `status`. Prints EXACTLY ONE of `new`, `needs-validation`,
#   or `likely-false-positive` on stdout. It NEVER emits `duplicate` (owned by
#   the dedup slice) and never writes `findings.jsonl` (owned by the ledger
#   slice) — it just returns the string for the ledger to store.
#
#   Two axes drive the decision:
#     anchors — `proof_anchors` array length >= 1 is "solid". A missing, null,
#               or non-array `proof_anchors` (e.g. a legacy singular string) is
#               defensively treated as 0 anchors so a stray scalar cannot pass
#               as solid evidence.
#     class   — the command class of `suggested_validation` (see
#               `_validation_command_class`): local / scanner / none / unknown.
#
#   Precedence — FIRST match wins:
#     1. class == scanner                     -> needs-validation
#        (external scanner required; aligns with the `external-dependency` type.
#        This dominates anchor strength: a scanner-gated finding is parked, not
#        discarded, regardless of anchors.)
#     2. solid anchors AND class == local     -> new
#        (locally validatable — issue rule 1.)
#     3. solid anchors AND class in {none,unknown} -> needs-validation
#        (real evidence but no runnable local check — park for validation.)
#     4. NO anchors AND class == local        -> needs-validation
#        (a cheap local check exists, so park rather than discard; research §6
#        recommendation 4a.)
#     5. NO anchors AND class in {none,unknown} -> likely-false-positive
#        (unsubstantiated and nothing to run — the conservative default.)
#   Corollary (issue rule 1): a finding with NO anchors NEVER classifies `new`.
#
#   Pure / jq-driven: the JSON is read with jq alone (so quotes, `$(...)`,
#   backticks, backslashes in the command string are data, never evaluated), and
#   the function has no side effects. Side effect: writes one status to stdout.
classify_validation_status() {
  local validation_json="${1:-}" anchors cmd cls status

  # Anchor strength. Anything that is not a JSON array counts as 0 anchors.
  anchors="$(jq -r \
    'if (.proof_anchors | type) == "array" then (.proof_anchors | length) else 0 end' \
    <<<"$validation_json" 2>/dev/null)"
  [[ "$anchors" =~ ^[0-9]+$ ]] || anchors=0

  # Command string (only honoured when it is a JSON string; null/missing -> "").
  cmd="$(jq -r \
    'if (.suggested_validation | type) == "string" then .suggested_validation else "" end' \
    <<<"$validation_json" 2>/dev/null)"

  cls="$(_validation_command_class "$cmd")"

  if [[ "$cls" == "scanner" ]]; then
    status="needs-validation"
  elif [[ "$anchors" -ge 1 ]]; then
    if [[ "$cls" == "local" ]]; then
      status="new"
    else
      status="needs-validation"
    fi
  else
    if [[ "$cls" == "local" ]]; then
      status="needs-validation"
    else
      status="likely-false-positive"
    fi
  fi

  printf '%s\n' "$status"
}
