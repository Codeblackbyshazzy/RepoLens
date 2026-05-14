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

# Unit tests for issue #213's agent failure classifier. The classifier should
# distinguish persistent auth/model/budget failures from rate limits and
# unknown failures so callers can abort globally with a precise stopped_reason.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/streak.sh"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures/agent-persistent-failures"

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
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
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

classify_fixture() {
  local file="$1" rc="${2:-1}"
  classify_agent_iteration "$file" "$rc" 2>/dev/null || printf 'missing-classifier'
}

echo "=== agent failure classification (issue #213) ==="

assert_eq "auth expired output is classified distinctly" \
  "auth-expired" \
  "$(classify_fixture "$FIXTURE_DIR/auth-expired.txt" 1)"

assert_eq "selected model failure is classified distinctly" \
  "model-unavailable" \
  "$(classify_fixture "$FIXTURE_DIR/model-unavailable.txt" 1)"

assert_eq "max budget failure is classified distinctly" \
  "budget-exhausted" \
  "$(classify_fixture "$FIXTURE_DIR/budget-exhausted.txt" 1)"

rate_limit_output="$TMPDIR/rate-limited.txt"
printf "ERROR: You've hit your usage limit. Try again at May 14th, 2026 11:00 PM.\n" > "$rate_limit_output"
assert_eq "existing rate-limit output remains rate-limited" \
  "rate-limited" \
  "$(classify_fixture "$rate_limit_output" 1)"

unknown_output="$TMPDIR/unknown.txt"
printf 'provider unavailable before producing output\n' > "$unknown_output"
assert_eq "generic non-zero failure remains unknown" \
  "unknown" \
  "$(classify_fixture "$unknown_output" 1)"

benign_success="$TMPDIR/benign-success.txt"
printf 'Finding: docs mention users may not be logged in after logout.\nDONE\n' > "$benign_success"
assert_eq "successful output is not classified as persistent failure" \
  "unknown" \
  "$(classify_fixture "$benign_success" 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
