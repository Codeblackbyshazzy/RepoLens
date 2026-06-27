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

# Tests for issue #334 — the validation `status` classifier (lib/validation.sh).
#
# `classify_validation_status <validation_json>` consumes the structured
# `validation` object that `parse_validation_block` (issue #332) emits and
# decides the registry `status` from TWO axes:
#   - anchor strength: proof_anchors array length (>= 1 == "solid").
#   - command class:   the `suggested_validation` string is a LOCAL runnable
#                      check (allowlist, first-token match) vs an EXTERNAL
#                      scanner (denylist, substring match).
#
# It prints EXACTLY ONE of `new` / `needs-validation` / `likely-false-positive`
# on stdout and NEVER `duplicate` (that status is owned by the dedup slice). It
# is pure: it reads its single JSON-string argument plus jq alone, sources with
# no side effects, and never writes findings.jsonl (storage is the ledger
# slice's job). These are BEHAVIORAL tests against the public contract from the
# issue's acceptance criteria — they do not assume internal helper or array
# names. No real AI models are invoked; this is a pure jq-driven function.
#
# Documented precedence under test (research.md §5.4 + §6, first match wins;
# `has` == proof_anchors length >= 1, `cls` == command class):
#   1. cls == scanner            -> needs-validation        (any anchors)
#   2. has && cls == local       -> new
#   3. has && cls in {none,unknown} -> needs-validation
#   4. !has && cls == local      -> needs-validation        (§6 recommendation 4a)
#   5. !has && cls in {none,unknown} -> likely-false-positive
# Issue rule 1 ("file:line anchor AND a local command -> new") means `new` is
# reachable ONLY with anchors: a finding with NO anchors must never classify
# `new`, regardless of command — an invariant we lock independently of the §6
# 4a-vs-4b choice.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATION_LIB="$SCRIPT_DIR/lib/validation.sh"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

# Assert two values differ (used for the "no-anchors never yields new" invariant).
assert_ne() {
  local desc="$1" forbidden="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$forbidden" != "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Value must NOT equal '$forbidden', but it did"
  fi
}

# Assert a classification is one of the three LEGAL classifier statuses — and,
# by construction, never `duplicate` (the fourth registry status, owned by
# dedup) nor any typo.
assert_member() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  case "$actual" in
    new | needs-validation | likely-false-positive)
      pass_with "$desc"
      ;;
    *)
      fail_with "$desc" "Got '$actual' — not a legal classify status (must never be 'duplicate' or anything outside the 3-set)"
      ;;
  esac
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

# Convenience: classify and capture stdout (trailing newline stripped by $(...)).
classify() {
  classify_validation_status "$1"
}

echo ""
echo "=== Test Suite: validation status classifier (issue #334) ==="
echo ""

# Red-phase guard: if the module does not exist yet, fail cleanly and stop.
if [[ ! -f "$VALIDATION_LIB" ]]; then
  fail_with "lib/validation.sh exists" "Missing $VALIDATION_LIB (not yet implemented)"
  finish
fi

echo "--- Group 1: sourceable module, classifier defined, no side effects ---"
# Sourcing must define functions only — no output, no work at source time.
# shellcheck disable=SC1090
source_out="$(source "$VALIDATION_LIB" 2>&1)"
assert_eq "sourcing lib/validation.sh emits nothing" "" "$source_out"

# shellcheck disable=SC1090
source "$VALIDATION_LIB"
TOTAL=$((TOTAL + 1))
if declare -F classify_validation_status >/dev/null 2>&1; then
  pass_with "classify_validation_status is defined after sourcing"
else
  fail_with "classify_validation_status is defined after sourcing"
  # Nothing else can be tested without the function — stop here (clean red phase).
  finish
fi

echo ""
echo "--- Group 2: the three required AC cases ---"
# 1. local command + anchors -> new (issue rule 1; research §8 test #1).
assert_eq "local cmd + anchors -> new" \
  "new" \
  "$(classify '{"proof_anchors":["app/users.py:42"],"suggested_validation":"grep -n \"SELECT\" app/users.py"}')"
# 2. external-scanner reference + anchors -> needs-validation (research §8 test #2).
assert_eq "scanner ref + anchors -> needs-validation" \
  "needs-validation" \
  "$(classify '{"proof_anchors":["pkg.json:3"],"suggested_validation":"needs external scanner — npm audit"}')"
# 3. no anchors, no command -> likely-false-positive (research §8 test #3).
assert_eq "no anchors + no command -> likely-false-positive" \
  "likely-false-positive" \
  "$(classify '{"proof_anchors":[],"suggested_validation":""}')"

echo ""
echo "--- Group 3: LOCAL allowlist breadth (first-token match) -> new ---"
# A multi-token local runner: first token `bash` is in the local allowlist.
assert_eq "bash tests/foo.sh + anchors -> new" \
  "new" \
  "$(classify '{"proof_anchors":["lib/x.sh:5"],"suggested_validation":"bash tests/foo.sh"}')"
# `test`/`[` style local predicate.
assert_eq "test -f ... + anchors -> new" \
  "new" \
  "$(classify '{"proof_anchors":["app.py:9"],"suggested_validation":"test -f config/domains.json"}')"

echo ""
echo "--- Group 4: curl is LOCAL only for localhost / 127.0.0.1 ---"
# curl against localhost is a local check -> new.
assert_eq "curl http://localhost:PORT + anchors -> new" \
  "new" \
  "$(classify '{"proof_anchors":["server.py:1"],"suggested_validation":"curl -s http://localhost:8080/health"}')"
assert_eq "curl http://127.0.0.1 + anchors -> new" \
  "new" \
  "$(classify '{"proof_anchors":["server.py:1"],"suggested_validation":"curl -s http://127.0.0.1:9000/"}')"
# curl against a remote host is NOT a local check (guards the special case):
# falls through to unknown -> needs-validation (anchors present, row 3). It must
# in particular NOT be promoted to `new`.
remote_curl="$(classify '{"proof_anchors":["server.py:1"],"suggested_validation":"curl -s https://example.com/x"}')"
assert_ne "curl to a remote host is NOT treated as local (not new)" "new" "$remote_curl"
assert_eq "curl to a remote host + anchors -> needs-validation" \
  "needs-validation" \
  "$remote_curl"

echo ""
echo "--- Group 5: EXTERNAL-scanner denylist (substring match) -> needs-validation ---"
# Bare scanner tool name, no "external scanner" phrase present.
assert_eq "semgrep --config auto + anchors -> needs-validation" \
  "needs-validation" \
  "$(classify '{"proof_anchors":["a.py:1"],"suggested_validation":"semgrep --config auto"}')"
assert_eq "trivy fs . + anchors -> needs-validation" \
  "needs-validation" \
  "$(classify '{"proof_anchors":["Dockerfile:1"],"suggested_validation":"trivy fs ."}')"
# Multi-word denylist entry matched as a substring (first token `npm` is not in
# the local allowlist; "npm audit" is the scanner signal).
assert_eq "npm audit + anchors -> needs-validation" \
  "needs-validation" \
  "$(classify '{"proof_anchors":["package.json:2"],"suggested_validation":"npm audit --production"}')"
# The literal phrase "external scanner" is the existing repo convention
# (artifacts.sh / human_review.sh / audit.md). The classifier must be a SUPERSET
# of that phrase match so all consumers agree — and the match is case-insensitive
# (real fixtures use mixed case, e.g. "Needs EXTERNAL Scanner ...").
assert_eq "literal 'external scanner' phrase (mixed case) + anchors -> needs-validation" \
  "needs-validation" \
  "$(classify '{"proof_anchors":["a.py:1"],"suggested_validation":"Needs EXTERNAL Scanner before acting"}')"

echo ""
echo "--- Group 6: allowlist (first-token) beats denylist (substring) ---"
# A genuine LOCAL grep that merely searches for the word "semgrep" must classify
# as local: first-token allowlist is evaluated before substring denylist. Guards
# the ordering in research §5.3 / risk #3.
assert_eq "grep -rn \"semgrep\" . + anchors -> new (local first-token wins)" \
  "new" \
  "$(classify '{"proof_anchors":["a.py:1"],"suggested_validation":"grep -rn \"semgrep\" ."}')"

echo ""
echo "--- Group 7: anchors but an unverifiable/empty command -> needs-validation ---"
# Anchors present, command empty -> can't auto-confirm locally -> park (row 3).
assert_eq "anchors + empty command -> needs-validation" \
  "needs-validation" \
  "$(classify '{"proof_anchors":["a.py:1"],"suggested_validation":""}')"
# Anchors present, command is neither a known local runner nor a scanner.
assert_eq "anchors + unrecognized command -> needs-validation" \
  "needs-validation" \
  "$(classify '{"proof_anchors":["a.py:1"],"suggested_validation":"frobnicate --all"}')"

echo ""
echo "--- Group 8: weak/missing anchors precedence ---"
# Scanner dominates the absence of anchors (row 1): no anchors + scanner is still
# parked for validation, not discarded.
assert_eq "no anchors + scanner -> needs-validation (row 1 dominates)" \
  "needs-validation" \
  "$(classify '{"proof_anchors":[],"suggested_validation":"semgrep ."}')"
# No anchors + a runnable LOCAL command -> needs-validation (the §6 documented
# call, recommendation 4a: a cheap local check exists, so park rather than drop).
assert_eq "no anchors + local command -> needs-validation (§6 4a)" \
  "needs-validation" \
  "$(classify '{"proof_anchors":[],"suggested_validation":"grep -n FIXME app.py"}')"
# No anchors + an unrecognized command -> unsubstantiated -> likely-false-positive
# (row 5: same outcome as no command at all).
assert_eq "no anchors + unrecognized command -> likely-false-positive" \
  "likely-false-positive" \
  "$(classify '{"proof_anchors":[],"suggested_validation":"frobnicate --all"}')"
# Invariant (issue rule 1): a finding with NO anchors must NEVER classify `new`,
# whatever the command — holds independently of the §6 4a-vs-4b decision.
for sv in '"grep -n x app.py"' '"semgrep ."' '""' '"frobnicate"' '"curl -s http://localhost/x"'; do
  na="$(classify "{\"proof_anchors\":[],\"suggested_validation\":$sv}")"
  assert_ne "no anchors never yields 'new' (cmd=$sv)" "new" "$na"
done

echo ""
echo "--- Group 9: defensive defaults (parser edge shapes) ---"
# The empty object {} is exactly what the parser emits for a finding with no
# `## Validation` block: 0 anchors + no command -> conservative default.
assert_eq "empty validation object {} -> likely-false-positive" \
  "likely-false-positive" \
  "$(classify '{}')"
# null fields must degrade to the conservative default rather than erroring under
# pipefail (// [] / // "").
assert_eq "explicit null fields -> likely-false-positive" \
  "likely-false-positive" \
  "$(classify '{"proof_anchors":null,"suggested_validation":null}')"
# A legacy/foreign singular `proof_anchor` (string) is NOT the parser's plural
# array contract; a non-array proof_anchors must be treated as 0 anchors so a
# stray scalar can't masquerade as "solid" and get promoted to `new` (risk #5).
singular="$(classify '{"proof_anchors":"app.py:1","suggested_validation":"grep -n x app.py"}')"
assert_ne "non-array proof_anchors is not mistaken for solid anchors (not new)" "new" "$singular"
assert_member "non-array proof_anchors still yields a legal status" "$singular"

echo ""
echo "--- Group 10: return value is ALWAYS legal and NEVER 'duplicate' ---"
# Acceptance criterion: returns exactly one of the three statuses for every input.
while IFS= read -r j; do
  [[ -z "$j" ]] && continue
  assert_member "classify legal-status guard for: $j" "$(classify "$j")"
done <<'EOF'
{"proof_anchors":["a:1"],"suggested_validation":"grep x f"}
{"proof_anchors":["a:1"],"suggested_validation":"semgrep ."}
{"proof_anchors":["a:1"],"suggested_validation":"needs external scanner — npm audit"}
{"proof_anchors":[],"suggested_validation":""}
{"proof_anchors":[],"suggested_validation":"curl -s http://localhost/x"}
{}
EOF

echo ""
echo "--- Group 11: injection safety (values flow through jq, never the shell) ---"
# The suggested_validation string is data, not code. A command-substitution that
# would classify DIFFERENTLY if evaluated proves the value is treated literally:
#   literal first token "$(echo" -> unknown -> needs-validation (anchors present)
#   if the shell evaluated it     -> "grep"  -> local   -> new
# So the result must be needs-validation (and never new).
inj_json="$(jq -cn --arg sv '$(echo grep) -n x.py' \
  '{proof_anchors:["app.py:1"], suggested_validation:$sv}')"
inj_status="$(classify "$inj_json")"
assert_ne "command-substitution in the command is NOT evaluated (not new)" "new" "$inj_status"
assert_eq "literal '\$(echo grep)' classifies by its literal first token -> needs-validation" \
  "needs-validation" \
  "$inj_status"
# A thoroughly hostile value (quote, semicolons, backticks, $(...), backslash)
# must not break classification or be interpreted — it just yields a legal status.
hostile_json="$(jq -cn --arg sv '"; rm -rf x; echo new `id` $(whoami) && \ end' \
  '{proof_anchors:["app.py:1"], suggested_validation:$sv}')"
assert_member "hostile suggested_validation still yields a legal status (no crash, no eval)" \
  "$(classify "$hostile_json")"

echo ""
echo "--- Group 12: purity — idempotent, no findings.jsonl side effect ---"
# Same input, two calls, byte-identical output.
idem_json='{"proof_anchors":["a:1"],"suggested_validation":"grep -n x a.py"}'
out1="$(classify "$idem_json")"
out2="$(classify "$idem_json")"
assert_eq "calling the classifier twice is deterministic" "$out1" "$out2"
# The classifier must NOT write findings.jsonl (or any file) into the CWD.
TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
PURE_DIR="$(mktemp -d "$TMPROOT/classifier-pure.XXXXXX")"
trap 'rm -rf "$PURE_DIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT
( cd "$PURE_DIR" && classify_validation_status "$idem_json" >/dev/null 2>&1 )
TOTAL=$((TOTAL + 1))
created="$(find "$PURE_DIR" -mindepth 1 -print -quit 2>/dev/null)"
if [[ -z "$created" ]]; then
  pass_with "classifier creates no files in CWD (no findings.jsonl side effect)"
else
  fail_with "classifier creates no files in CWD" "Unexpected file created: $created"
fi

echo ""
echo "--- Group 13: allowlist token & whitespace edge cases (distinct branches) ---"
# `[` is a deliberate allowlist token; the implementation compares it with a
# QUOTED rhs so it is matched literally and NOT read as a glob bracket. Guards
# that quoting: a `[ -f ... ]` predicate is a local check -> new.
assert_eq "[ -f ... ] predicate + anchors -> new (literal '[' token, not a glob)" \
  "new" \
  "$(classify '{"proof_anchors":["a:1"],"suggested_validation":"[ -f config/domains.json ]"}')"
# First-token matching is case-insensitive (the command's first token is
# lowercased before allowlist comparison). An UPPERCASE/mixed-case local runner
# must still classify as local -> new. Mirrors the case-insensitive scanner
# phrase match already locked in Group 5.
assert_eq "UPPERCASE 'GREP ...' + anchors -> new (first-token match is case-insensitive)" \
  "new" \
  "$(classify '{"proof_anchors":["a:1"],"suggested_validation":"GREP -n x app.py"}')"
assert_eq "mixed-case 'Sed ...' + anchors -> new (first-token match is case-insensitive)" \
  "new" \
  "$(classify '{"proof_anchors":["a:1"],"suggested_validation":"Sed -n 1p app.py"}')"
# The command is trimmed before its first token is extracted, so leading
# whitespace must not defeat the allowlist match.
assert_eq "leading-whitespace local command + anchors -> new (command is trimmed first)" \
  "new" \
  "$(classify '{"proof_anchors":["a:1"],"suggested_validation":"   grep -n x app.py"}')"
# A whitespace-ONLY command trims to empty -> class `none` (a distinct branch
# from a genuinely empty string). With anchors that is row 3 -> needs-validation;
# with no anchors it is row 5 -> likely-false-positive (same as no command).
assert_eq "whitespace-only command + anchors -> needs-validation (trims to none)" \
  "needs-validation" \
  "$(classify '{"proof_anchors":["a:1"],"suggested_validation":"   "}')"
assert_eq "whitespace-only command + no anchors -> likely-false-positive (trims to none)" \
  "likely-false-positive" \
  "$(classify '{"proof_anchors":[],"suggested_validation":"   "}')"
# curl is local for the loopback host over HTTPS too (the issue lists
# `https://localhost` explicitly); Group 4 only exercises the http:// forms.
assert_eq "curl https://localhost + anchors -> new (loopback over https)" \
  "new" \
  "$(classify '{"proof_anchors":["server.py:1"],"suggested_validation":"curl -s https://localhost:8443/health"}')"

finish
