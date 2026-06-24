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

# RepoLens — evidence-ledger / finding-registry helpers.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects. It depends on no globals — every function works purely from
# its arguments — so it is safe to source alone under `set -uo pipefail`.
#
# The finding registry (`logs/<run-id>/final/findings.jsonl`, schema in
# docs/finding-registry-schema.md) needs a STABLE `id` so the same finding
# earns the same id across runs and across both source paths (manifest
# clusters and `--local` markdown frontmatter). This module owns that id.
#
# NOTE: this is a DIFFERENT identity from the verifier's per-run
# `_round_digest_finding_id` (lib/rounds.sh): that one is SHA-1 over
# lens/domain/round/suspect-files for matching verification.json entries.
# The registry id below is title-derived (content-stable, not suspect-file
# derived) and carries an `fnd-` prefix to keep the two visually distinct.

# _ledger_normalize_title <title>
#   Normalizes a finding title for stable hashing: lowercases, strips an
#   optional leading "[severity]" prefix (only when the bracketed word is a
#   real severity), collapses non-alphanumeric runs to single spaces, trims.
#
#   Prefers the shared `_synthesize_normalize_title` (lib/synthesize.sh) when
#   it is already sourced, so the two stay in lockstep; otherwise falls back to
#   a self-contained replica so lib/ledger.sh works when sourced on its own.
_ledger_normalize_title() {
  if declare -F _synthesize_normalize_title >/dev/null 2>&1; then
    _synthesize_normalize_title "$1"
    return
  fi

  # Self-contained replica of lib/synthesize.sh::_synthesize_normalize_title.
  # The severity word set (critical|high|medium|low) is inlined to match
  # lib/core.sh::severity_normalize without taking a hard dependency on it.
  local title="${1:-}"
  if [[ "$title" =~ ^\[([A-Za-z]+)\][[:space:]]*(.*)$ ]]; then
    case "${BASH_REMATCH[1],,}" in
      critical|high|medium|low) title="${BASH_REMATCH[2]}" ;;
    esac
  fi
  title="${title,,}"
  local out="" ch i len="${#title}"
  for (( i = 0; i < len; i++ )); do
    ch="${title:i:1}"
    case "$ch" in
      [a-z0-9]) out+="$ch" ;;
      *) out+=' ' ;;
    esac
  done
  out="${out## }"
  out="${out%% }"
  while [[ "$out" == *"  "* ]]; do
    out="${out//  / }"
  done
  printf '%s' "$out"
}

# _ledger_sha256_hex
#   Reads stdin and prints its lowercase SHA-256 as 64 hex chars. Mirrors the
#   repo's hash cascade (lib/forge.sh::_forge_label_set_hash): sha256sum, then
#   shasum -a 256. No cksum fallback here — the finding id must be a real,
#   collision-resistant content hash, and both tools are present on this host.
_ledger_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# finding_id <domain> <lens> <title> [primary_location]
#   Prints a stable, content-derived finding id of the form `fnd-<12 hex>`.
#
#   The title argument is normalized internally (see _ledger_normalize_title),
#   so casing, a leading "[severity]" prefix, and punctuation differences do
#   not change the id. The canonical pre-image is the four fields joined by the
#   ASCII Unit Separator (US, 0x1F), SHA-256 hashed, truncated to 12 hex chars.
#
#   `primary_location` is optional; when omitted it hashes as an empty trailing
#   field (stable). Deterministic: identical args always yield the same id.
finding_id() {
  local domain="${1:-}" lens="${2:-}" title="${3:-}" location="${4:-}"
  local sep=$'\037' norm hex

  norm="$(_ledger_normalize_title "$title")"
  hex="$(printf '%s' "${domain}${sep}${lens}${sep}${norm}${sep}${location}" \
    | _ledger_sha256_hex)"

  printf 'fnd-%s\n' "${hex:0:12}"
}

# _ledger_severity_normalize <value>
#   Canonicalizes a severity to critical|high|medium|low (or "" for anything
#   else). Prefers the shared severity_normalize (lib/core.sh) when it is
#   already sourced; otherwise falls back to a self-contained replica so
#   lib/ledger.sh keeps working when sourced on its own (the same defensive
#   pattern used by _ledger_normalize_title above).
_ledger_severity_normalize() {
  if declare -F severity_normalize >/dev/null 2>&1; then
    severity_normalize "$1"
    return
  fi

  # Self-contained replica of lib/core.sh::severity_normalize.
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$value" == \[*\] ]]; then
    value="${value#\[}"
    value="${value%\]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  fi
  value="${value,,}"
  case "$value" in
    critical|high|medium|low) printf '%s' "$value" ;;
    *) printf '' ;;
  esac
}

# build_findings_jsonl_from_manifest <manifest_path> <out_jsonl_path>
#   Reads a validated synthesizer manifest (logs/<run-id>/final/manifest.json:
#   a JSON array of cluster objects) and writes the canonical finding registry
#   as JSON Lines — one record per cluster, mapped onto the 12-field schema in
#   docs/finding-registry-schema.md plus a source_finding_paths passthrough.
#
#   Pure: reads the manifest, writes the out file. No required globals;
#   severity_normalize (lib/core.sh) is used when present, else an inline
#   replica (see _ledger_severity_normalize) keeps this sourceable alone.
#
#   Field mapping (notable points):
#   - id        is content-derived via finding_id with an EMPTY primary_location
#               (the manifest carries no file:line); stable across runs.
#   - severity  is run through _ledger_severity_normalize (e.g. "High"->"high").
#   - status    defaults to "new"; verification_status "wrong" ->
#               "likely-false-positive", "stale" -> "needs-validation";
#               everything else (verified/unknown/absent) -> "new"
#               (conservative — "verified" is still "new" to the registry).
#   - duplicate_group is SEEDED from cluster_id; the final dedup grouping is
#               owned by the dedupe agent (#316/#322/#335). cluster_id is a
#               per-run, non-stable handle and must not be confused with id.
#   - type/confidence/markdown_path are null and primary_location is "";
#     validation is an empty object {}. These are owned by sibling agents.
#   - source_finding_paths is passed through verbatim so siblings can trace
#     the underlying evidence.
#
#   jq owns all quoting/escaping: the whole entry is handed to jq via
#   --argjson and fields are read inside jq, so titles/paths with quotes,
#   newlines, shell metacharacters, or unicode survive intact. Only the three
#   computed scalars (id, severity, status) are passed as --arg.
#
#   Empty manifest ([]) -> empty out file (0 lines), exit 0. Output is written
#   atomically (tmp + mv) so a mid-loop failure leaves no partial registry.
#   Returns non-zero on missing args, a missing manifest, or non-array JSON
#   (no output is written in those cases).
build_findings_jsonl_from_manifest() {
  local manifest="${1:-}" out="${2:-}"
  [[ -n "$manifest" ]] || { echo "build_findings_jsonl_from_manifest: missing manifest path" >&2; return 2; }
  [[ -n "$out" ]]      || { echo "build_findings_jsonl_from_manifest: missing out path" >&2; return 2; }
  [[ -f "$manifest" ]] || { echo "build_findings_jsonl_from_manifest: manifest not found: $manifest" >&2; return 2; }
  jq -e 'type == "array"' "$manifest" >/dev/null 2>&1 \
    || { echo "build_findings_jsonl_from_manifest: not a JSON array: $manifest" >&2; return 1; }

  local tmp="${out}.tmp.$$"
  : > "$tmp" || return 1

  local count i entry domain lens title raw_sev sev vstatus status id
  count="$(jq 'length' "$manifest")" || { rm -f "$tmp"; return 1; }
  for (( i = 0; i < count; i++ )); do
    entry="$(jq -c --argjson i "$i" '.[$i]' "$manifest")" || { rm -f "$tmp"; return 1; }
    domain="$(jq -r '.domain // ""'  <<<"$entry")"
    lens="$(jq -r   '.lens // ""'    <<<"$entry")"
    title="$(jq -r  '.title // ""'   <<<"$entry")"
    raw_sev="$(jq -r '.severity // ""' <<<"$entry")"
    vstatus="$(jq -r '.verification_status // ""' <<<"$entry")"

    id="$(finding_id "$domain" "$lens" "$title")"
    sev="$(_ledger_severity_normalize "$raw_sev")"
    status="new"
    case "$vstatus" in
      wrong) status="likely-false-positive" ;;
      stale) status="needs-validation" ;;
    esac

    jq -cn \
      --argjson entry "$entry" \
      --arg id "$id" --arg severity "$sev" --arg status "$status" '
      {
        id: $id,
        title: ($entry.title // ""),
        severity: $severity,
        type: null,
        domain: ($entry.domain // ""),
        lens: ($entry.lens // ""),
        status: $status,
        primary_location: "",
        confidence: null,
        duplicate_group: ($entry.cluster_id // null),
        markdown_path: null,
        validation: {},
        source_finding_paths: ($entry.source_finding_paths // [])
      }' >> "$tmp" || { rm -f "$tmp"; return 1; }
  done

  mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}

# _ledger_trim_yaml_value <raw>
#   Trims surrounding whitespace, then strips one surrounding pair of matching
#   double or single quotes. A frontmatter `title: "[high] X"` must de-quote to
#   the bare `[high] X` so it earns the SAME finding_id as the manifest path
#   (the surrounding quotes otherwise prevent the [severity] prefix from being
#   stripped during normalization — an id-divergence bug). Self-contained
#   replica of lib/rounds.sh::_round_digest_trim_yaml_value (no dependency, to
#   keep lib/ledger.sh sourceable on its own).
_ledger_trim_yaml_value() {
  local v="$*"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v#\"}"; v="${v%\"}"
  v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

# _ledger_has_frontmatter <file>
#   Returns 0 iff the file's first line is exactly `---` AND a closing `---`
#   line exists below it. This is the validity gate used to skip malformed /
#   frontmatter-less files. The closing-delimiter flag guards the END exit so a
#   well-formed block reports success even though the rule already returned.
_ledger_has_frontmatter() {
  awk '
    NR==1 && $0!="---" { exit 1 }
    NR==1 { next }
    $0=="---" { found=1; exit 0 }
    END { if (!found) exit 1 }
  ' "$1"
}

# _ledger_frontmatter_scalar <file> <key>
#   Prints the raw (still-quoted) value of a scalar key found inside the leading
#   `---` frontmatter block, or nothing when the key is absent. Reads ONLY the
#   block (stops at the closing `---`), so a `key:`-looking line in the markdown
#   body cannot be misparsed. Validity is checked separately by
#   _ledger_has_frontmatter; this reader has no END block so its rule exits are
#   authoritative (printing the value never gets clobbered by a guard).
_ledger_frontmatter_scalar() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR==1 && $0!="---" { exit 0 }
    NR==1 { next }
    $0=="---" { exit 0 }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      sub("^[[:space:]]*" key "[[:space:]]*:[[:space:]]*", "")
      print
      exit 0
    }
  ' "$file"
}

# build_findings_jsonl_from_local <output_dir> <out_jsonl_path>
#   Ingests the markdown findings written by `--local` mode into the canonical
#   finding registry as JSON Lines. Recursively finds every `*.md` under
#   <output_dir>, parses each file's leading YAML frontmatter
#   (title/severity/domain/lens) and emits one registry record per file that
#   carries a valid frontmatter block, mapped onto the 12-field schema in
#   docs/finding-registry-schema.md.
#
#   Sibling of build_findings_jsonl_from_manifest (#314): same null-slot
#   conventions and the same atomic-write + jq-owns-escaping discipline, with
#   two deliberate differences —
#   - markdown_path is POPULATED with the .md file's path (the point of #319:
#     link the registry row back to the human-readable file). The path is
#     emitted exactly as `find` yields it (i.e. relative to / prefixed by
#     <output_dir>), so it opens directly from where the registry lives.
#   - duplicate_group is null and source_finding_paths is OMITTED: local runs
#     have no synthesizer clusters, so there is nothing to seed or pass through.
#
#   Field sourcing:
#   - title/severity/domain/lens come from the frontmatter (YAML-dequoted).
#   - domain/lens fall back to directory components
#     (<output_dir>/<domain>/<lens>/NNN-x.md) ONLY when the frontmatter omits
#     them AND the nesting depth exists; a flat <output_dir>/NNN-x.md without
#     frontmatter domain/lens leaves them "" (no bogus value from the dir name).
#   - id is content-derived via finding_id over the DE-QUOTED title (no
#     primary_location), so the same finding earns the same id whether it
#     arrived via a manifest cluster or a local .md file.
#   - severity is run through _ledger_severity_normalize ("Critical"->"critical").
#   - type/confidence are null, primary_location is "", validation is {},
#     status is "new" (owned by sibling agents).
#
#   jq owns all quoting/escaping: title/domain/lens/markdown_path are passed as
#   --arg and the object is built inside jq, so titles with quotes, `$()`,
#   backticks, or unicode round-trip intact and are never shell-evaluated.
#
#   A file without a valid frontmatter block is skipped with a stderr warning
#   (not fatal — the function still returns 0). An empty / no-`.md` dir yields an
#   empty output file (0 lines), exit 0. find output is sorted so rebuilds are
#   byte-identical. Output is written atomically (tmp + mv). Returns non-zero on
#   missing args or a missing <output_dir>, and on a missing out-path parent dir
#   (the atomic write fails) — no output is written in those cases.
build_findings_jsonl_from_local() {
  local dir="${1:-}" out="${2:-}"
  [[ -n "$dir" ]] || { echo "build_findings_jsonl_from_local: missing output_dir" >&2; return 2; }
  [[ -n "$out" ]] || { echo "build_findings_jsonl_from_local: missing out path" >&2; return 2; }
  [[ -d "$dir" ]] || { echo "build_findings_jsonl_from_local: output_dir not found: $dir" >&2; return 2; }

  local tmp="${out}.tmp.$$"
  : > "$tmp" || return 1

  local file rel title severity domain lens id sev
  while IFS= read -r -d '' file; do
    # Skip + warn (not fatal) when there is no valid leading frontmatter block.
    if ! _ledger_has_frontmatter "$file"; then
      echo "build_findings_jsonl_from_local: no valid frontmatter, skipping: $file" >&2
      continue
    fi

    title="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$file" title)")"
    severity="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$file" severity)")"
    domain="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$file" domain)")"
    lens="$(_ledger_trim_yaml_value "$(_ledger_frontmatter_scalar "$file" lens)")"

    # Directory fallback only when the <domain>/<lens> nesting actually exists.
    # rel like <domain>/<lens>/NNN-x.md has 3+ path components; a flat file does
    # not, so we never derive a bogus domain/lens from <output_dir>'s own name.
    rel="${file#"$dir"/}"
    if [[ -z "$domain" || -z "$lens" ]] && [[ "$rel" == */*/* ]]; then
      [[ -z "$lens"   ]] && lens="$(basename "$(dirname "$file")")"
      [[ -z "$domain" ]] && domain="$(basename "$(dirname "$(dirname "$file")")")"
    fi

    id="$(finding_id "$domain" "$lens" "$title")"
    sev="$(_ledger_severity_normalize "$severity")"

    jq -cn \
      --arg id "$id" --arg title "$title" --arg severity "$sev" \
      --arg domain "$domain" --arg lens "$lens" --arg md "$file" '
      {
        id: $id,
        title: $title,
        severity: $severity,
        type: null,
        domain: $domain,
        lens: $lens,
        status: "new",
        primary_location: "",
        confidence: null,
        duplicate_group: null,
        markdown_path: $md,
        validation: {}
      }' >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < <(find "$dir" -type f -name '*.md' -print0 | LC_ALL=C sort -z)

  mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}

# build_findings_csv <findings_jsonl_path> <out_csv_path>
#   Projects the canonical finding registry (findings.jsonl, schema in
#   docs/finding-registry-schema.md) onto a flat CSV: a fixed 11-column header
#   row, then one row per JSONL line, preserving JSONL line order
#   (deterministic). Spreadsheet/grep users get a flat view without a second
#   source of truth — findings.jsonl stays the full-fidelity registry.
#
#   Columns (exactly, in this order):
#     id,title,severity,type,domain,lens,status,primary_location,confidence,
#     duplicate_group,markdown_path
#   The nested `validation` object and the `source_finding_paths` array are
#   OMITTED — they don't flatten to a single cell. Keep this column list in
#   lockstep with the jq array below; the header string and the array are two
#   parallel lists (tests/test_ledger_csv.sh asserts the header byte-for-byte).
#
#   jq -r @csv owns all CSV quoting/escaping (RFC-4180): a field containing a
#   comma, a double quote, or a newline is correctly quoted and inner quotes are
#   doubled. A JSON null (or an absent key) renders as a bare empty cell.
#   Numbers (e.g. confidence) render unquoted. Fields are read inside jq, so
#   titles with shell metacharacters or unicode are never shell-evaluated.
#
#   Sibling of build_findings_jsonl_from_{manifest,local}: same atomic-write
#   (tmp + mv) + jq-owns-escaping discipline. Pure: reads the JSONL, writes the
#   CSV. An empty findings.jsonl yields a header-only CSV (matching the empty,
#   zero-line registry), exit 0. Returns non-zero on missing args or a missing
#   input file (no output written), and on a jq/IO failure (tmp cleaned up).
build_findings_csv() {
  local in="${1:-}" out="${2:-}"
  [[ -n "$in" ]]  || { echo "build_findings_csv: missing findings.jsonl path" >&2; return 2; }
  [[ -n "$out" ]] || { echo "build_findings_csv: missing out path" >&2; return 2; }
  [[ -f "$in" ]]  || { echo "build_findings_csv: input not found: $in" >&2; return 2; }

  local tmp="${out}.tmp.$$"
  # Header first. Keep this list in lockstep with the jq array below.
  printf '%s\n' \
    'id,title,severity,type,domain,lens,status,primary_location,confidence,duplicate_group,markdown_path' \
    > "$tmp" || return 1

  # One CSV row per JSONL value (jq streams values in input order). Raw field
  # access (no `// ""`) so a JSON null becomes a bare empty cell, not the
  # literal "null". An empty input yields zero rows -> header-only CSV, exit 0.
  jq -r '
    [ .id, .title, .severity, .type, .domain, .lens, .status,
      .primary_location, .confidence, .duplicate_group, .markdown_path ]
    | @csv
  ' "$in" >> "$tmp" || { rm -f "$tmp"; return 1; }

  mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}

# validate_findings_jsonl <findings_jsonl_path>
#   Validates the JSON-Lines finding registry (schema:
#   docs/finding-registry-schema.md) PER LINE. This is the last line of defense
#   so siblings (dedupe/validation/triage/html/csv) can trust the structure even
#   if a builder regresses or a future producer writes the file. It mirrors
#   validate_manifest's reporting discipline (every message to stderr, prefixed
#   "validate_findings_jsonl: ...", accumulate-then-return), but iterates line by
#   line because JSONL is one independent JSON object per line: a single jq pass
#   would abort on the first malformed line, skip every line after it, and could
#   not attribute a violation to a line number.
#
#   Per non-empty line it asserts: the line parses as a JSON object; the 12
#   required keys are present (id, title, severity, type, domain, lens, status,
#   primary_location, confidence, duplicate_group, markdown_path, validation); id
#   is a non-empty string; severity in {critical,high,medium,low}; status in
#   {new,duplicate,needs-validation,likely-false-positive}; a non-null, non-empty
#   type in {security,reliability,performance,maintainability,test-gap,
#   external-dependency} (null/empty type accepted — owned by finding-types);
#   validation is an object (internals NOT checked — owned by validation-hints).
#   Extra/forward-compatible keys (e.g. source_finding_paths) are tolerated.
#
#   Empty file -> 0. Returns 0 when every line is valid, 1 on any violation,
#   2 on missing arg / missing file. Pure: reads only, no writes, no model.
validate_findings_jsonl() {
  local findings="${1:-}"
  if [[ -z "$findings" ]]; then
    echo "validate_findings_jsonl: missing findings.jsonl path" >&2
    return 2
  fi
  if [[ ! -f "$findings" ]]; then
    echo "validate_findings_jsonl: findings.jsonl not found: $findings" >&2
    return 2
  fi

  local errors=0 lineno=0 line out rc violation
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # Skip genuinely blank lines (e.g. a trailing newline). lineno is still
    # incremented above so reported numbers match what an editor shows.
    [[ -n "${line//[[:space:]]/}" ]] || continue

    # One jq pass per line emits one violation string per problem. The
    # `if type != "object"` guard is load-bearing: has(...) on a non-object
    # raises a jq error, so we branch on object-ness first. A valid-but-non-object
    # line (e.g. a bare array/scalar) parses with rc=0 and falls into the
    # "not a JSON object" arm; an unparseable line makes jq exit non-zero and is
    # caught by the rc != 0 arm below. Enum checks are guarded by has(...) so a
    # MISSING key reports only "missing required key: ..." without duplicate noise.
    out="$(jq -r '
      def is_nonempty_string: type == "string" and length > 0;
      def severities: ["critical","high","medium","low"];
      def statuses:   ["new","duplicate","needs-validation","likely-false-positive"];
      def types:      ["security","reliability","performance","maintainability","test-gap","external-dependency"];
      if type != "object" then "not a JSON object"
      else
        . as $v
        | (
            (["id","title","severity","type","domain","lens","status","primary_location","confidence","duplicate_group","markdown_path","validation"][] as $k
              | select(($v | has($k)) | not)
              | "missing required key: \($k)"),
            (if ($v | has("id")) and ($v.id | is_nonempty_string | not)
               then "id must be a non-empty string" else empty end),
            (if ($v | has("severity")) and ((severities | index($v.severity)) == null)
               then "invalid severity: \($v.severity | tostring)" else empty end),
            (if ($v | has("status")) and ((statuses | index($v.status)) == null)
               then "invalid status: \($v.status | tostring)" else empty end),
            (if ($v.type != null and $v.type != "") and ((types | index($v.type)) == null)
               then "invalid type: \($v.type | tostring)" else empty end),
            (if ($v | has("validation")) and (($v.validation | type) != "object")
               then "validation must be an object" else empty end)
          )
      end
    ' <<<"$line" 2>/dev/null)"
    rc=$?

    if (( rc != 0 )); then
      # jq could not parse the line -> not valid JSON (and so not an object).
      echo "validate_findings_jsonl: line $lineno: not a JSON object" >&2
      errors=$((errors + 1))
      continue
    fi

    while IFS= read -r violation; do
      [[ -n "$violation" ]] || continue
      echo "validate_findings_jsonl: line $lineno: $violation" >&2
      errors=$((errors + 1))
    done <<< "$out"
  done < "$findings"

  (( errors == 0 )) || return 1
  return 0
}
