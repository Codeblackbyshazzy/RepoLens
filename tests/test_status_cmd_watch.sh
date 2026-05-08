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

# Behavioral tests for issue #122: watch mode keeps re-rendering until an
# interrupt instead of exiting after the first snapshot.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

echo "=== status command watch mode ==="
status_require_jq

if ! command -v timeout >/dev/null 2>&1; then
  echo "  SKIP: timeout(1) not available"
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit 0
fi

RUN_ID="status-watch-test"
RUN_DIR="$STATUS_TEST_ROOT/logs/$RUN_ID"
OUT_FILE="$STATUS_TEST_TMPDIR/watch.out"
ERR_FILE="$STATUS_TEST_TMPDIR/watch.err"
mkdir -p "$RUN_DIR"
status_register_run_id "$RUN_ID"
jq --arg run "$RUN_ID" '.run_id = $run' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" > "$RUN_DIR/status.json"

TERM=dumb timeout --signal=INT 3s bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN_ID" --watch 1 --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
output="$(cat "$OUT_FILE")"
stderr="$(cat "$ERR_FILE")"
render_count="$(grep -c "RepoLens run $RUN_ID" "$OUT_FILE" || true)"

assert_eq "Watch mode exits cleanly on SIGINT timeout" "124" "$rc"
assert_eq "Watch mode does not write stderr on interrupt" "" "$stderr"
TOTAL=$((TOTAL + 1))
if (( render_count >= 2 )); then
  record_pass "Watch mode renders the run more than once"
else
  record_fail "Watch mode renders the run more than once" "render_count=$render_count"
fi
assert_contains "Watch output includes selected run" "RepoLens run status-watch-test" "$output"

STALE_RUN_ID="status-watch-stale-test"
STALE_RUN_DIR="$STATUS_TEST_ROOT/logs/$STALE_RUN_ID"
mkdir -p "$STALE_RUN_DIR"
status_register_run_id "$STALE_RUN_ID"
jq --arg run "$STALE_RUN_ID" '.run_id = $run' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_stale.json" > "$STALE_RUN_DIR/status.json"

TERM=dumb timeout --signal=INT 3s bash "$STATUS_TEST_ROOT/repolens.sh" status "$STALE_RUN_ID" --watch 1 --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
stale_output="$(cat "$OUT_FILE")"
stale_render_count="$(grep -c "RepoLens run $STALE_RUN_ID" "$OUT_FILE" || true)"

assert_eq "Stale watch mode keeps running until interrupted" "124" "$rc"
TOTAL=$((TOTAL + 1))
if (( stale_render_count >= 2 )); then
  record_pass "Stale watch mode renders more than once"
else
  record_fail "Stale watch mode renders more than once" "render_count=$stale_render_count"
fi
assert_contains "Stale watch output still marks stale worker" "[STALE?]" "$stale_output"

status_finish
