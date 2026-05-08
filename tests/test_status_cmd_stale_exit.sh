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

# Behavioral tests for issue #122: stale active workers are visible and make
# one-shot status renders exit with code 2.

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

echo "=== status command stale worker exit code ==="
status_require_jq

RUN_ID="status-stale-test"
RUN_DIR="$STATUS_TEST_ROOT/logs/$RUN_ID"
OUT_FILE="$STATUS_TEST_TMPDIR/status.out"
ERR_FILE="$STATUS_TEST_TMPDIR/status.err"
mkdir -p "$RUN_DIR"
status_register_run_id "$RUN_ID"
cp "$STATUS_TEST_ROOT/tests/fixtures/status_stale.json" "$RUN_DIR/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN_ID" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
output="$(cat "$OUT_FILE")"

assert_eq "Stale status render exits 2" "2" "$rc"
assert_eq "Stale status render does not write stderr" "" "$(cat "$ERR_FILE")"
assert_contains "Stale output includes active lens key" "security/xss" "$output"
assert_contains "Stale output marks stale heartbeat" "[STALE?]" "$output"
assert_contains "Stale output still shows heartbeat age" "hb 2m 05s ago" "$output"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN_ID" --no-color --stale-after 300 >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
override_output="$(cat "$OUT_FILE")"

assert_eq "Raised stale threshold exits 0" "0" "$rc"
assert_not_contains "Raised stale threshold suppresses stale marker" "[STALE?]" "$override_output"

status_finish
