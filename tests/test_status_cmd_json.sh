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

# Behavioral tests for issue #122: --json emits status.json verbatim.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

echo "=== status command raw JSON mode ==="
status_require_jq

RUN_ID="status-json-test"
RUN_DIR="$STATUS_TEST_ROOT/logs/$RUN_ID"
OUT_FILE="$STATUS_TEST_TMPDIR/status.json.out"
ERR_FILE="$STATUS_TEST_TMPDIR/status.json.err"
mkdir -p "$RUN_DIR"
status_register_run_id "$RUN_ID"
jq --arg run "$RUN_ID" '.run_id = $run' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" > "$RUN_DIR/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN_ID" --json >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?

assert_eq "JSON status exits 0 for non-stale run" "0" "$rc"
assert_eq "JSON status does not write stderr" "" "$(cat "$ERR_FILE")"
TOTAL=$((TOTAL + 1))
if cmp -s "$RUN_DIR/status.json" "$OUT_FILE"; then
  record_pass "JSON status output is byte-for-byte status.json"
else
  record_fail "JSON status output is byte-for-byte status.json"
fi

STALE_RUN_ID="status-json-stale-test"
STALE_RUN_DIR="$STATUS_TEST_ROOT/logs/$STALE_RUN_ID"
mkdir -p "$STALE_RUN_DIR"
status_register_run_id "$STALE_RUN_ID"
jq --arg run "$STALE_RUN_ID" '.run_id = $run' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_stale.json" > "$STALE_RUN_DIR/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$STALE_RUN_ID" --json >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?

assert_eq "JSON status preserves stale exit code 2" "2" "$rc"
assert_eq "Stale JSON status does not write stderr" "" "$(cat "$ERR_FILE")"
TOTAL=$((TOTAL + 1))
if cmp -s "$STALE_RUN_DIR/status.json" "$OUT_FILE"; then
  record_pass "Stale JSON status output is byte-for-byte status.json"
else
  record_fail "Stale JSON status output is byte-for-byte status.json"
fi

status_finish
