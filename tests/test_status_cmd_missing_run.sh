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

# Behavioral tests for issue #122: missing and invalid status files fail with
# status-specific errors and list usable runs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    record_fail "$desc" "unexpected needle='$needle'"
  else
    record_pass "$desc"
  fi
}

echo "=== status command missing run errors ==="
status_require_jq

AVAILABLE_RUN="status-available-test"
mkdir -p "$STATUS_TEST_ROOT/logs/$AVAILABLE_RUN"
status_register_run_id "$AVAILABLE_RUN"
jq --arg run "$AVAILABLE_RUN" '.run_id = $run' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" > "$STATUS_TEST_ROOT/logs/$AVAILABLE_RUN/status.json"

OUT_FILE="$STATUS_TEST_TMPDIR/status.out"
ERR_FILE="$STATUS_TEST_TMPDIR/status.err"

bash "$STATUS_TEST_ROOT/repolens.sh" status bogus-run --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
output="$(cat "$OUT_FILE")"
stderr="$(cat "$ERR_FILE")"

assert_eq "Missing named run exits 1" "1" "$rc"
assert_eq "Missing named run writes no stdout" "" "$output"
assert_contains "Missing run error names requested run" "bogus-run" "$stderr"
assert_contains "Missing run error mentions status.json" "status.json" "$stderr"
assert_contains "Missing run error lists available runs" "Available runs:" "$stderr"
assert_contains "Missing run error includes available status run" "$AVAILABLE_RUN" "$stderr"
assert_not_contains "Missing run error avoids normal required-argument validation" "Missing required argument" "$stderr"

bash "$STATUS_TEST_ROOT/repolens.sh" status ../outside --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
path_stderr="$(cat "$ERR_FILE")"

assert_eq "Path-like run id exits 1" "1" "$rc"
assert_contains "Path-like run id is rejected as invalid" "Invalid run id" "$path_stderr"
assert_not_contains "Path-like run id is not treated as a normal parser error" "Unknown argument" "$path_stderr"

MALFORMED_RUN="status-malformed-test"
mkdir -p "$STATUS_TEST_ROOT/logs/$MALFORMED_RUN"
status_register_run_id "$MALFORMED_RUN"
printf '{not valid json}\n' > "$STATUS_TEST_ROOT/logs/$MALFORMED_RUN/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$MALFORMED_RUN" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
malformed_stderr="$(cat "$ERR_FILE")"

assert_eq "Malformed status exits 1" "1" "$rc"
assert_contains "Malformed status error names status file" "status.json" "$malformed_stderr"
assert_contains "Malformed status error mentions invalid JSON" "Invalid" "$malformed_stderr"

status_finish
