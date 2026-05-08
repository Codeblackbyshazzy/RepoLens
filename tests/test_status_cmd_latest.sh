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

# Behavioral tests for issue #122: no-arg status selects the newest direct
# logs/<run-id>/status.json and ignores non-run log directories.

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

echo "=== status command selects the newest available run ==="
status_require_jq

OLDER_RUN="status-latest-old"
NEWER_RUN="status-latest-new"
EMPTY_LOG="status-latest-empty"
mkdir -p "$STATUS_TEST_ROOT/logs/$OLDER_RUN" "$STATUS_TEST_ROOT/logs/$NEWER_RUN" "$STATUS_TEST_ROOT/logs/$EMPTY_LOG"
status_register_run_id "$OLDER_RUN"
status_register_run_id "$NEWER_RUN"
status_register_run_id "$EMPTY_LOG"

jq --arg run "$OLDER_RUN" '.run_id = $run | .repo = "older/repo"' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" > "$STATUS_TEST_ROOT/logs/$OLDER_RUN/status.json"
jq --arg run "$NEWER_RUN" '.run_id = $run | .repo = "newer/repo"' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" > "$STATUS_TEST_ROOT/logs/$NEWER_RUN/status.json"

touch -t 202605080300 "$STATUS_TEST_ROOT/logs/$OLDER_RUN" "$STATUS_TEST_ROOT/logs/$OLDER_RUN/status.json"
touch -t 202605080301 "$STATUS_TEST_ROOT/logs/$NEWER_RUN" "$STATUS_TEST_ROOT/logs/$NEWER_RUN/status.json"
touch -t 202605080302 "$STATUS_TEST_ROOT/logs/$EMPTY_LOG"
touch "$STATUS_TEST_ROOT/logs/$NEWER_RUN/status.json"

OUT_FILE="$STATUS_TEST_TMPDIR/status.out"
ERR_FILE="$STATUS_TEST_TMPDIR/status.err"
bash "$STATUS_TEST_ROOT/repolens.sh" status --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
output="$(cat "$OUT_FILE")"
stderr="$(cat "$ERR_FILE")"

assert_eq "No-arg status render exits 0" "0" "$rc"
assert_eq "No-arg status render does not write stderr" "" "$stderr"
assert_contains "No-arg status selects newest status.json" "RepoLens run status-latest-new" "$output"
assert_contains "No-arg status renders newest repo" "newer/repo" "$output"
assert_not_contains "No-arg status does not select older run" "status-latest-old" "$output"
assert_not_contains "No-arg status ignores newer log child without status.json" "$EMPTY_LOG" "$output"
assert_not_contains "No-arg status ignores logs/issues" "RepoLens run issues" "$output"

status_finish
