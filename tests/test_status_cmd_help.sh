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

# Behavioral tests for issue #122: help and status-specific parser errors are
# separate from normal run argument parsing.

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

echo "=== status command help and parser behavior ==="

OUT_FILE="$STATUS_TEST_TMPDIR/help.out"
ERR_FILE="$STATUS_TEST_TMPDIR/help.err"

bash "$STATUS_TEST_ROOT/repolens.sh" --help >"$OUT_FILE" 2>"$ERR_FILE"
assert_eq "Top-level help exits 0" "0" "$?"
top_help="$(cat "$OUT_FILE")"
assert_contains "Top-level help lists status command" "repolens.sh status [run-id]" "$top_help"

bash "$STATUS_TEST_ROOT/repolens.sh" status --help >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
status_help="$(cat "$OUT_FILE")"
status_stderr="$(cat "$ERR_FILE")"

assert_eq "Status help exits 0" "0" "$rc"
assert_eq "Status help does not write stderr" "" "$status_stderr"
assert_contains "Status help shows status usage" "Usage: repolens.sh status [run-id]" "$status_help"
assert_contains "Status help documents raw JSON flag" "--json" "$status_help"
assert_contains "Status help documents watch flag" "--watch [seconds]" "$status_help"
assert_contains "Status help documents stale threshold flag" "--stale-after <seconds>" "$status_help"
assert_contains "Status help documents no-color flag" "--no-color" "$status_help"

bash "$STATUS_TEST_ROOT/repolens.sh" status --unknown >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
unknown_stderr="$(cat "$ERR_FILE")"
assert_eq "Unknown status flag exits 1" "1" "$rc"
assert_contains "Unknown status flag reports status-specific parser error" "Unknown status option" "$unknown_stderr"
assert_not_contains "Unknown status flag avoids normal parser error" "Unknown argument" "$unknown_stderr"

bash "$STATUS_TEST_ROOT/repolens.sh" status first second >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
extra_stderr="$(cat "$ERR_FILE")"
assert_eq "Extra status run id exits 1" "1" "$rc"
assert_contains "Extra status run id reports status-specific parser error" "Unexpected status argument" "$extra_stderr"

bash "$STATUS_TEST_ROOT/repolens.sh" status --watch 0 >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
watch_stderr="$(cat "$ERR_FILE")"
assert_eq "Zero watch interval exits 1" "1" "$rc"
assert_contains "Zero watch interval reports invalid interval" "Invalid --watch interval" "$watch_stderr"

bash "$STATUS_TEST_ROOT/repolens.sh" status --stale-after nope >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
stale_stderr="$(cat "$ERR_FILE")"
assert_eq "Non-numeric stale threshold exits 1" "1" "$rc"
assert_contains "Non-numeric stale threshold reports invalid threshold" "Invalid --stale-after" "$stale_stderr"

status_finish
