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

# Tests for issue #211: shared non-lens phase rate-limit handling.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-rate-limit-phase-helper"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

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

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect file $path"
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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== _handle_agent_rate_limit_in_phase ==="

LOG_BASE="$TMPDIR/logs/run-rate-limited"
SUMMARY_FILE="$LOG_BASE/summary.json"
mkdir -p "$LOG_BASE"
printf '{"stopped_reason":null,"lenses":[]}\n' > "$SUMMARY_FILE"
export LOG_BASE SUMMARY_FILE

rate_limited_output="$TMPDIR/rate-limited.txt"
printf "ERROR: You've hit your usage limit. Try again at May 14th, 2026 11:00 PM.\n" > "$rate_limited_output"

_handle_agent_rate_limit_in_phase "verifier" "$rate_limited_output" >"$TMPDIR/handled.out" 2>"$TMPDIR/handled.err"
status=$?
assert_success "rate-limit output is handled" "$status"
assert_file_exists "handled output creates rate-limit sentinel" "$LOG_BASE/.rate-limit-abort"
assert_eq "handled output records phase-specific stop reason" "rate-limited-verifier" "$(jq -r '.stopped_reason' "$SUMMARY_FILE")"

LOG_BASE="$TMPDIR/logs/run-generic-failure"
SUMMARY_FILE="$LOG_BASE/summary.json"
mkdir -p "$LOG_BASE"
printf '{"stopped_reason":null,"lenses":[]}\n' > "$SUMMARY_FILE"
export LOG_BASE SUMMARY_FILE

generic_output="$TMPDIR/generic-failure.txt"
printf 'agent crashed before producing a manifest\n' > "$generic_output"

_handle_agent_rate_limit_in_phase "synthesizer" "$generic_output" >"$TMPDIR/generic.out" 2>"$TMPDIR/generic.err"
status=$?
assert_failure "generic failure output is not handled as rate-limit" "$status"
assert_file_missing "generic failure does not create sentinel" "$LOG_BASE/.rate-limit-abort"
assert_eq "generic failure leaves stop reason unset" "null" "$(jq -r '.stopped_reason' "$SUMMARY_FILE")"

finish
