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

# Tests for issue #149: round prompt variables and pipe-safe context rendering.

# shellcheck disable=SC1091,SC2034,SC2329 # Runtime sources consume test globals and indirect helpers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/template.sh
source "$SCRIPT_DIR/lib/template.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-round-template-vars"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to find: $needle"
  fi
}

assert_file_contains() {
  local desc="$1" file="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $file to contain: $needle"
  fi
}

assert_file_not_contains() {
  local desc="$1" file="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if ! grep -qF "$needle" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect $file to contain: $needle"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

cat > "$TMPDIR/lens.md" <<'EOF'
---
id: test-lens
domain: test
name: Test Lens
role: tester
---
## Your Expert Focus
Focus on the round prompt context.
EOF

cat > "$TMPDIR/digest.md" <<'EOF'
# Round Digest

| lens | findings |
| injection | 2 |

Review the auth | session boundary.
Preserve `inline code`, ampersand & marker, backslash \ marker, and <angle> markers.
Literal placeholders must stay literal: {{SPEC_SECTION}}, {{SOURCE_SECTION}}, and {{MAX_ISSUES_SECTION}}.
EOF

cat > "$TMPDIR/hypotheses.md" <<'EOF'
- Verify auth | session issue with fresh code evidence.
- Re-check multi-line hypothesis handling.
- Confirm {{HOSTED_SECTION}} remains literal planning text.
- Confirm {{LOCAL_MODE_SECTION}} remains literal planning text.
EOF

cat > "$TMPDIR/spec.md" <<'EOF'
Spec content that must render only in the spec section.
EOF

cat > "$TMPDIR/source.md" <<'EOF'
Source content that must render only in the source section.
EOF

base_vars="LENS_NAME=RoundBot|DOMAIN_NAME=Security|REPO_OWNER=owner|REPO_NAME=repo|PROJECT_PATH=/tmp/project|LENS_LABEL=audit:security/injection|DOMAIN_COLOR=ededed|DOMAIN=security|LENS_ID=injection|MODE=audit|RUN_ID=test-run"

echo "=== round prompt variable rendering (issue #149) ==="

echo ""
echo "Test 1: audit template renders pipe-safe prior digest and hypotheses"
rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/audit.md" "$TMPDIR/lens.md" "${base_vars}|ROUND_INDEX=2|ROUND_TOTAL=3|PRIOR_ROUND_DIGEST=@${TMPDIR}/digest.md|HYPOTHESES_TO_VERIFY=@${TMPDIR}/hypotheses.md" "$TMPDIR/spec.md" "audit" "" "$TMPDIR/source.md")"

assert_contains "round context section is present" "## Round Context" "$rendered"
assert_contains "round index and total render" "round **2 of 3**" "$rendered"
assert_contains "digest markdown table keeps pipe characters" "| injection | 2 |" "$rendered"
assert_contains "digest prose keeps pipe characters" "auth | session" "$rendered"
assert_contains "digest keeps backticks" '`inline code`' "$rendered"
assert_contains "digest keeps ampersand" "ampersand & marker" "$rendered"
assert_contains "digest keeps backslash" "backslash \\ marker" "$rendered"
assert_contains "digest keeps angle brackets" "<angle> markers" "$rendered"
assert_contains "digest keeps SPEC_SECTION literal" "{{SPEC_SECTION}}" "$rendered"
assert_contains "digest keeps SOURCE_SECTION literal" "{{SOURCE_SECTION}}" "$rendered"
assert_contains "digest keeps MAX_ISSUES_SECTION literal" "{{MAX_ISSUES_SECTION}}" "$rendered"
assert_contains "hypothesis list keeps pipe characters" "Verify auth | session issue" "$rendered"
assert_contains "multiline hypotheses survive" "Re-check multi-line hypothesis handling." "$rendered"
assert_contains "hypotheses keep HOSTED_SECTION literal" "{{HOSTED_SECTION}}" "$rendered"
assert_contains "hypotheses keep LOCAL_MODE_SECTION literal" "{{LOCAL_MODE_SECTION}}" "$rendered"
assert_not_contains "ROUND_CONTEXT_SECTION placeholder is consumed" "{{ROUND_CONTEXT_SECTION}}" "$rendered"
assert_not_contains "PRIOR_ROUND_DIGEST placeholder is consumed" "{{PRIOR_ROUND_DIGEST}}" "$rendered"
assert_not_contains "HYPOTHESES_TO_VERIFY placeholder is consumed" "{{HYPOTHESES_TO_VERIFY}}" "$rendered"

echo ""
echo "Test 2: single-round prompt collapses the optional round section"
single_round="$(compose_prompt "$SCRIPT_DIR/prompts/_base/audit.md" "$TMPDIR/lens.md" "$base_vars" "" "audit")"
assert_not_contains "single round omits round context header" "## Round Context" "$single_round"
assert_not_contains "single round consumes round context placeholder" "{{ROUND_CONTEXT_SECTION}}" "$single_round"
assert_not_contains "unset prompt omits ROUND_INDEX placeholder" "{{ROUND_INDEX}}" "$single_round"
assert_not_contains "unset prompt omits ROUND_TOTAL placeholder" "{{ROUND_TOTAL}}" "$single_round"
assert_not_contains "unset prompt omits prior digest placeholder" "{{PRIOR_ROUND_DIGEST}}" "$single_round"
assert_not_contains "unset prompt omits hypotheses placeholder" "{{HYPOTHESES_TO_VERIFY}}" "$single_round"

echo ""
echo "Test 3: multi-round base prompts include the self-collapsing round slot"
for mode in audit feature bugfix custom; do
  assert_file_contains "$mode base prompt has ROUND_CONTEXT_SECTION" \
                       "$SCRIPT_DIR/prompts/_base/$mode.md" \
                       "{{ROUND_CONTEXT_SECTION}}"
done

echo ""
echo "Test 4: repolens.sh passes round variables only when state is set"
assert_file_contains "repolens.sh conditionally passes ROUND_INDEX" \
                     "$SCRIPT_DIR/repolens.sh" \
                     '[[ -n "${CURRENT_ROUND_INDEX:-}" ]] && vars+="|ROUND_INDEX=${CURRENT_ROUND_INDEX}"'
assert_file_contains "repolens.sh conditionally passes ROUND_TOTAL" \
                     "$SCRIPT_DIR/repolens.sh" \
                     '[[ -n "${CURRENT_ROUND_TOTAL:-}" ]] && vars+="|ROUND_TOTAL=${CURRENT_ROUND_TOTAL}"'
assert_file_contains "repolens.sh passes prior digest file when present" \
                     "$SCRIPT_DIR/repolens.sh" \
                     'vars+="|PRIOR_ROUND_DIGEST=@${PRIOR_ROUND_DIGEST_FILE}"'
assert_file_contains "repolens.sh passes hypotheses file when present" \
                     "$SCRIPT_DIR/repolens.sh" \
                     'vars+="|HYPOTHESES_TO_VERIFY=@${HYPOTHESES_TO_VERIFY_FILE}"'
assert_file_not_contains "repolens.sh does not append empty prior digest" \
                         "$SCRIPT_DIR/repolens.sh" \
                         'vars+="|PRIOR_ROUND_DIGEST="'
assert_file_not_contains "repolens.sh does not append empty hypotheses" \
                         "$SCRIPT_DIR/repolens.sh" \
                         'vars+="|HYPOTHESES_TO_VERIFY="'

echo ""
echo "Test 5: run_rounds exposes prior round files to later lenses"
log_info() {
  :
}

log_warn() {
  :
}

# shellcheck source=../lib/rounds.sh
source "$SCRIPT_DIR/lib/rounds.sh"

RUN_CONTEXTS=()
META_CALLS=()

run_lens() {
  RUN_CONTEXTS+=("${CURRENT_ROUND_INDEX:-}|${CURRENT_ROUND_TOTAL:-}|${PRIOR_ROUND_DIGEST_FILE:-}|${HYPOTHESES_TO_VERIFY_FILE:-}|${CURRENT_ROUND_OUTPUT_DIR:-}")
}

run_meta_orchestrator() {
  local round="$1" next_round="$2" hypotheses_path
  META_CALLS+=("$round->$next_round")
  hypotheses_path="$(round_hypotheses_path "$RUN_ID" "$round")" || return $?
  printf '%s\n' '- Verify follow-up | hypothesis.' > "$hypotheses_path"
}

RUN_ID="round-vars"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
SUMMARY_FILE="$TMPDIR/summary.json"
PARALLEL=false
LOCAL_MODE=true
OUTPUT_DIR_SET=false
OUTPUT_DIR=""
MAX_ISSUES=""
GLOBAL_ISSUES_CREATED=0
TOTAL_LENSES=1
LENSES=("security/injection")

init_run_layout "$RUN_ID" 2 1 "${LENSES[@]}"
run_rounds 2 LENSES
rc=$?
assert_eq "run_rounds exits successfully" "0" "$rc"
assert_eq "run_lens is called once per round" "2" "${#RUN_CONTEXTS[@]}"
assert_eq "meta handoff occurs between rounds" "1->2" "${META_CALLS[*]}"

IFS='|' read -r round1 total1 digest1 hypotheses1 output1 <<< "${RUN_CONTEXTS[0]}"
IFS='|' read -r round2 total2 digest2 hypotheses2 output2 <<< "${RUN_CONTEXTS[1]}"

assert_eq "round 1 index is exposed" "1" "$round1"
assert_eq "round 1 total is exposed" "2" "$total1"
assert_eq "round 1 has no prior digest" "" "$digest1"
assert_eq "round 1 has no hypotheses file" "" "$hypotheses1"
assert_eq "round 1 default local output is round-scoped" "$LOG_BASE/rounds/round-1/lens-outputs" "$output1"

assert_eq "round 2 index is exposed" "2" "$round2"
assert_eq "round 2 total is exposed" "2" "$total2"
assert_eq "round 2 prior digest points to round 1" "$LOG_BASE/rounds/round-1/digest.md" "$digest2"
assert_eq "round 2 hypotheses point to round 1" "$LOG_BASE/rounds/round-1/hypotheses.md" "$hypotheses2"
assert_eq "round 2 default local output is round-scoped" "$LOG_BASE/rounds/round-2/lens-outputs" "$output2"
assert_file_exists "round 1 digest exists before round 2" "$digest2"
assert_file_exists "round 1 hypotheses exist before round 2" "$hypotheses2"

echo ""
echo "Test 6: run_rounds prefers hypotheses prepared for the current round"
RUN_CONTEXTS=()
META_CALLS=()

run_meta_orchestrator() {
  local round="$1" next_round="$2" hypotheses_path
  META_CALLS+=("$round->$next_round")
  hypotheses_path="$(round_hypotheses_path "$RUN_ID" "$next_round")" || return $?
  printf '%s\n' '- Verify next-round prepared hypothesis.' > "$hypotheses_path"
}

RUN_ID="round-vars-next"
LOG_BASE="$TMPDIR/logs/$RUN_ID"
SUMMARY_FILE="$TMPDIR/summary-next.json"
init_run_layout "$RUN_ID" 2 1 "${LENSES[@]}"
run_rounds 2 LENSES
rc=$?
assert_eq "next-round hypotheses run exits successfully" "0" "$rc"
assert_eq "next-round meta handoff occurs" "1->2" "${META_CALLS[*]}"

IFS='|' read -r _round2_next _total2_next _digest2_next hypotheses2_next _output2_next <<< "${RUN_CONTEXTS[1]}"
assert_eq "round 2 hypotheses prefer current round prepared file" "$LOG_BASE/rounds/round-2/hypotheses.md" "$hypotheses2_next"
assert_file_exists "round 2 prepared hypotheses exist before lens dispatch" "$hypotheses2_next"

finish
