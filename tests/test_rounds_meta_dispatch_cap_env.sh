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

# Issue #233 — REPOLENS_META_ORCH_DISPATCH_CAP must:
#   - default to 3 server-side (so missing template substitution does not
#     leak `{{DISPATCH_CAP}}` into prompts),
#   - be honored by the parser (cap counts across LENS+GENERIC+CUSTOM total),
#   - allow lifting (cap=5 accepts 5 LENS lines),
#   - drop the tail when cap<emitted.
# shellcheck disable=SC2034,SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-meta-dispatch-cap-env"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  [[ -n "${2:-}" ]] && printf '    %s\n' "$2"
}

assert_eq() {
  TOTAL=$((TOTAL + 1))
  if [[ "$2" == "$3" ]]; then
    pass_with "$1"
  else
    fail_with "$1" "Expected: $2 | Actual: $3"
  fi
}

assert_contains() {
  TOTAL=$((TOTAL + 1))
  if [[ "$3" == *"$2"* ]]; then
    pass_with "$1"
  else
    fail_with "$1" "Expected to find: $2"
  fi
}

assert_not_contains() {
  TOTAL=$((TOTAL + 1))
  if [[ "$3" != *"$2"* ]]; then
    pass_with "$1"
  else
    fail_with "$1" "Did not expect to find: $2"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  (( FAIL > 0 )) && exit 1
  exit 0
}

write_lens() {
  local domain="$1" lens="$2" dir
  dir="$TMPDIR/lenses/$domain"
  mkdir -p "$dir"
  cat > "$dir/$lens.md" <<EOF
---
id: $lens
domain: $domain
name: $lens
role: tester
---
## Your Expert Focus
Test lens.
EOF
}

LOG_LINES=()
log_info() { :; }
log_warn() { LOG_LINES+=("WARN:$*"); }

echo "=== REPOLENS_META_ORCH_DISPATCH_CAP enforcement (issue #233) ==="

# Stand up several real lens IDs (must match config/domains.json entries) so
# the validator accepts them.
write_lens security injection
write_lens code-quality dead-code
write_lens security xss-csrf
write_lens security secrets
write_lens security auth-session
LENSES_DIR="$TMPDIR/lenses"
MODE="audit"
unset CURRENT_ROUND_INDEX || true

echo ""
echo "Test 1: default cap is 3 (server-side default)"
unset REPOLENS_META_ORCH_DISPATCH_CAP || true
default_cap="$(_rounds_meta_dispatch_cap)"
assert_eq "default cap is 3" "3" "$default_cap"

echo ""
echo "Test 2: invalid env value falls back to 3"
REPOLENS_META_ORCH_DISPATCH_CAP="not-a-number"
fallback_cap="$(_rounds_meta_dispatch_cap)"
assert_eq "non-numeric cap falls back to 3" "3" "$fallback_cap"
REPOLENS_META_ORCH_DISPATCH_CAP="0"
zero_cap="$(_rounds_meta_dispatch_cap)"
assert_eq "zero cap falls back to 3" "3" "$zero_cap"
unset REPOLENS_META_ORCH_DISPATCH_CAP

echo ""
echo "Test 3: cap=5 accepts 5 LENS lines (cap lifted)"
REPOLENS_META_ORCH_DISPATCH_CAP=5
cat > "$TMPDIR/meta-five.txt" <<'EOF'
## Round 2 dispatch plan
LENS: injection
LENS: dead-code
LENS: xss-csrf
LENS: secrets
LENS: auth-session
HYPOTHESES_TO_VERIFY:
- All five.
EOF
LOG_LINES=()
_rounds_meta_parse_output "$TMPDIR/meta-five.txt" "$TMPDIR/dispatch-five.md" "$TMPDIR/hypotheses-five.md" "$LENSES_DIR"
five_dispatch="$(cat "$TMPDIR/dispatch-five.md")"
assert_contains "cap=5 keeps LENS: injection" "LENS: injection" "$five_dispatch"
assert_contains "cap=5 keeps LENS: dead-code" "LENS: dead-code" "$five_dispatch"
assert_contains "cap=5 keeps LENS: xss-csrf" "LENS: xss-csrf" "$five_dispatch"
assert_contains "cap=5 keeps LENS: secrets" "LENS: secrets" "$five_dispatch"
assert_contains "cap=5 keeps LENS: auth-session" "LENS: auth-session" "$five_dispatch"
unset REPOLENS_META_ORCH_DISPATCH_CAP

echo ""
echo "Test 4: cap=2 truncates to 2 LENS lines and warns"
REPOLENS_META_ORCH_DISPATCH_CAP=2
cat > "$TMPDIR/meta-two.txt" <<'EOF'
## Round 2 dispatch plan
LENS: injection
LENS: dead-code
LENS: xss-csrf
HYPOTHESES_TO_VERIFY:
- Top two.
EOF
LOG_LINES=()
_rounds_meta_parse_output "$TMPDIR/meta-two.txt" "$TMPDIR/dispatch-two.md" "$TMPDIR/hypotheses-two.md" "$LENSES_DIR"
two_dispatch="$(cat "$TMPDIR/dispatch-two.md")"
assert_contains "cap=2 keeps first LENS" "LENS: injection" "$two_dispatch"
assert_contains "cap=2 keeps second LENS" "LENS: dead-code" "$two_dispatch"
assert_not_contains "cap=2 drops the tail" "LENS: xss-csrf" "$two_dispatch"
joined_log="${LOG_LINES[*]:-}"
assert_contains "cap enforcement is logged" "dispatch cap enforced" "$joined_log"
unset REPOLENS_META_ORCH_DISPATCH_CAP

echo ""
echo "Test 5: prompt-vars helper exports DISPATCH_CAP variable"
PROJECT_PATH="$TMPDIR/project"
vars="$(_rounds_meta_prompt_vars 1 2 "$TMPDIR/digest.md" "$PROJECT_PATH")"
assert_contains "DISPATCH_CAP is present in vars string" "DISPATCH_CAP=3" "$vars"

REPOLENS_META_ORCH_DISPATCH_CAP=5
vars5="$(_rounds_meta_prompt_vars 1 2 "$TMPDIR/digest.md" "$PROJECT_PATH")"
assert_contains "DISPATCH_CAP reflects env override" "DISPATCH_CAP=5" "$vars5"
unset REPOLENS_META_ORCH_DISPATCH_CAP

echo ""
echo "Test 6: meta-orchestrator prompt renders DISPATCH_CAP, never leaks raw token"
mkdir -p "$TMPDIR/proj"
printf 'digest body\n' > "$TMPDIR/digest.md"
vars_default="$(_rounds_meta_prompt_vars 1 2 "$TMPDIR/digest.md" "$TMPDIR/proj")"
rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/meta_orchestrator.md" \
                           "$SCRIPT_DIR/prompts/_base/meta_orchestrator.md" \
                           "$vars_default" "" "audit")"
assert_not_contains "rendered prompt does not contain raw {{DISPATCH_CAP}}" '{{DISPATCH_CAP}}' "$rendered"
assert_contains "rendered prompt substitutes default cap into 'name N angles'" "name 3 angles NOT yet covered" "$rendered"

finish
