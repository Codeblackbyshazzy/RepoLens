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

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; }

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then pass_with "$desc"; else fail_with "$desc" "Missing: $needle"; fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected '$expected', got '$actual'"; fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  (( FAIL == 0 )) || exit 1
}

echo "=== --min-severity flag plumbing ==="

help_text="$(bash "$SCRIPT_DIR/repolens.sh" --help 2>&1)"
assert_contains "usage documents --min-severity" "--min-severity <level>" "$help_text"
assert_contains "usage documents env fallback" "REPOLENS_MIN_SEVERITY" "$help_text"

script_text="$(cat "$SCRIPT_DIR/repolens.sh")"
assert_contains "parser has --min-severity branch" "--min-severity)" "$script_text"
assert_contains "parser requires a severity argument" "Option --min-severity requires an argument" "$script_text"
assert_contains "env fallback is wired" 'REPOLENS_MIN_SEVERITY+x' "$script_text"
assert_contains "validation uses severity_normalize" 'MIN_SEVERITY="$(severity_normalize "$MIN_SEVERITY")"' "$script_text"
assert_contains "normalized value is exported" "export REPOLENS_MIN_SEVERITY" "$script_text"

assert_eq "uppercase CLI value normalizes" "high" "$(severity_normalize "HIGH")"
assert_eq "bracketed env value normalizes" "medium" "$(severity_normalize "[Medium]")"

TMPDIR="$(mktemp -d "$SCRIPT_DIR/logs/test-min-severity-flag.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/project"
invalid_output="$(bash "$SCRIPT_DIR/repolens.sh" --project "$TMPDIR/project" --agent claude --local --yes --min-severity URGENT 2>&1 >/dev/null)"
invalid_rc=$?
TOTAL=$((TOTAL + 1))
if [[ "$invalid_rc" -ne 0 ]]; then
  pass_with "invalid min severity exits non-zero"
else
  fail_with "invalid min severity exits non-zero" "Expected non-zero exit"
fi
assert_contains "invalid min severity lists accepted values" "critical, high, medium, low" "$invalid_output"

finish
