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

# Behavioral tests for issue #122: the public status subcommand renders a
# named status.json run snapshot without invoking a real RepoLens audit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

assert_matches() {
  local desc="$1" regex="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" =~ $regex ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "actual='${actual:-<empty>}' pattern='$regex'"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    record_fail "$desc" "unexpected needle='$needle'"
  else
    record_pass "$desc"
  fi
}

echo "=== status command renders a named run ==="
status_require_jq

RUN_ID="status-active-test"
RUN_DIR="$STATUS_TEST_ROOT/logs/$RUN_ID"
OUT_FILE="$STATUS_TEST_TMPDIR/status.out"
ERR_FILE="$STATUS_TEST_TMPDIR/status.err"
mkdir -p "$RUN_DIR"
status_register_run_id "$RUN_ID"
cp "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" "$RUN_DIR/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN_ID" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
output="$(cat "$OUT_FILE")"
stderr="$(cat "$ERR_FILE")"
started_line="$(grep -m1 '^  started:' "$OUT_FILE" || true)"
updated_line="$(grep -m1 '^  updated:' "$OUT_FILE" || true)"

assert_eq "Named status render exits 0" "0" "$rc"
assert_eq "Named status render does not write stderr" "" "$stderr"
assert_contains "Output includes run id" "RepoLens run status-active-test" "$output"
assert_contains "Output includes repo slug" "project:   TheMorpheus407/RepoLens" "$output"
assert_contains "Output includes mode, agent, and parallel width" "(audit, claude, parallel x8)" "$output"
assert_contains "Output includes started absolute timestamp" "started:   2026-04-17 03:00:00 UTC" "$output"
assert_matches "Started line includes relative age" '^  started:.*\([^)]+ ago\)' "$started_line"
assert_contains "Output includes updated absolute timestamp" "updated:   2026-04-17 07:27:00 UTC" "$output"
assert_matches "Updated line includes relative age" '^  updated:.*\([^)]+ ago\)' "$updated_line"
assert_contains "Output includes progress counters" "progress:  24/152 completed  |  8 active  |  120 queued  |  17 issues created" "$output"
assert_contains "Output includes active table heading" "Active lenses:" "$output"
assert_contains "Output includes active lens key" "security/injection" "$output"
assert_contains "Output includes active iteration" "iter 3" "$output"
assert_contains "Output includes active running duration" "running 4m 23s" "$output"
assert_contains "Output includes active heartbeat age" "hb 12s ago" "$output"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN_ID" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
parser_rc=$?
parser_output="$(cat "$OUT_FILE")$(cat "$ERR_FILE")"
assert_eq "Status command avoids normal required-argument validation" "0" "$parser_rc"
assert_contains "Status command still renders through early dispatch" "RepoLens run status-active-test" "$parser_output"

FINISHED_RUN_ID="status-finished-test"
FINISHED_RUN_DIR="$STATUS_TEST_ROOT/logs/$FINISHED_RUN_ID"
mkdir -p "$FINISHED_RUN_DIR"
status_register_run_id "$FINISHED_RUN_ID"
jq '.run_id = "status-finished-test"
    | .state = "finished"
    | .repo = ""
    | .parallel = false
    | .max_parallel = 0
    | .counts.active = 0
    | .counts.queued = 0
    | .counts.completed = 152
    | .completion_percentage = 100
    | .active = []
    | .queued = []
    | .completed = ["security/injection"]' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" > "$FINISHED_RUN_DIR/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$FINISHED_RUN_ID" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
finished_rc=$?
finished_output="$(cat "$OUT_FILE")"

assert_eq "Finished status render exits 0" "0" "$finished_rc"
assert_contains "Finished output falls back to project path" "project:   /workspace/RepoLens" "$finished_output"
assert_contains "Finished output shows sequential execution" "(audit, claude, sequential)" "$finished_output"
assert_contains "Finished output shows completed counters" "progress:  152/152 completed  |  0 active  |  0 queued  |  17 issues created" "$finished_output"
assert_contains "Finished output reports no active lenses" "No active lenses." "$finished_output"

SANITIZED_RUN_ID="status-sanitized-test"
SANITIZED_RUN_DIR="$STATUS_TEST_ROOT/logs/$SANITIZED_RUN_ID"
mkdir -p "$SANITIZED_RUN_DIR"
status_register_run_id "$SANITIZED_RUN_ID"
control_run_id=$'status-\033[31msanitized'
control_repo=$'TheMorpheus407/\033[31mRepoLens'
long_lens_id="very-long-lens-name-that-should-truncate-and-not-break-status-table"
jq --arg run "$control_run_id" \
   --arg repo "$control_repo" \
   --arg lens "$long_lens_id" \
   '.run_id = $run
    | .repo = $repo
    | .active[0].domain = "security"
    | .active[0].lens_id = $lens
    | .active = [.active[0]]
    | .counts.active = 1' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" > "$SANITIZED_RUN_DIR/status.json"

bash "$STATUS_TEST_ROOT/repolens.sh" status "$SANITIZED_RUN_ID" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
sanitized_rc=$?
sanitized_output="$(cat "$OUT_FILE")"

assert_eq "Sanitized status render exits 0" "0" "$sanitized_rc"
assert_not_contains "Human render strips terminal escape bytes" $'\033' "$sanitized_output"
assert_contains "Human render truncates long active lens keys" "security/very-long-lens..." "$sanitized_output"
assert_not_contains "Human render does not emit full overlong lens key" "$long_lens_id" "$sanitized_output"

status_finish
