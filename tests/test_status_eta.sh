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

# Issue #347 — elapsed + estimated-remaining time in status.json.
#
# Drives write_status_snapshot directly (unit-style, no agent invocation).
# Determinism comes from a backdated started_at: the function captures "now"
# internally, so a started_at far in the past makes elapsed_seconds large and
# positive on every machine/clock. Each case uses a fresh log dir so the
# running-over-terminal skip guard never trips.

# shellcheck disable=SC2329 # Helpers are invoked indirectly by the test harness.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/status.sh
source "$SCRIPT_DIR/lib/status.sh"
trap status_cleanup EXIT

log_warn() {
  :
}

echo "=== status.json elapsed + ETA fields (issue #347) ==="
status_require_jq

ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# build_case <dir> <started_at> <lenses> <completed>
# Creates a fresh log dir with summary.json, .status-lenses, .completed, and an
# empty heartbeat dir. <lenses>/<completed> are newline-delimited lens keys.
build_case() {
  local dir="$1" started_at="$2" lenses="$3" completed="$4"
  mkdir -p "$dir/.heartbeat"
  cat > "$dir/summary.json" <<JSON
{
  "run_id": "eta-case",
  "started_at": "$started_at"
}
JSON
  printf '%s' "$lenses" > "$dir/.status-lenses"
  printf '%s' "$completed" > "$dir/.completed"
}

# write_case <dir> <state>: invoke the public snapshot writer for that dir.
write_case() {
  local dir="$1" state="$2"
  write_status_snapshot \
    "$state" \
    "eta-case" \
    "$dir" \
    "$dir/.heartbeat" \
    "$dir/.completed" \
    "$dir/summary.json" \
    "/tmp/project" \
    "owner/repo" \
    "audit" \
    "codex" \
    "true" \
    "8" \
    "$dir/.status-lenses"
}

# --- Case A: running, 1 of 3 completed -> positive integer ETA -------------
CASE_A="$STATUS_TEST_TMPDIR/eta-running-partial"
build_case "$CASE_A" "2026-01-02T03:04:05Z" $'a/x\na/y\na/z\n' $'a/x\n'
if write_case "$CASE_A" "running"; then
  assert_eq "Case A: snapshot write succeeds" "0" "0"
else
  assert_eq "Case A: snapshot write succeeds" "0" "1"
fi
A_STATUS="$CASE_A/status.json"
assert_jq "Case A: output is valid JSON" "$A_STATUS" '.'
assert_jq "Case A: status.json gains the three time fields" "$A_STATUS" \
  'has("elapsed_seconds") and has("eta_seconds_remaining") and has("eta_completion_at")'
assert_jq "Case A: elapsed_seconds is a positive number" "$A_STATUS" \
  '.elapsed_seconds | type == "number" and . > 0'
assert_jq "Case A: eta_seconds_remaining is a positive integer" "$A_STATUS" \
  '.eta_seconds_remaining | type == "number" and . > 0 and . == (. | floor)'
assert_jq "Case A: eta follows the linear rate (~2x elapsed for 1/3 done)" "$A_STATUS" \
  '.eta_seconds_remaining >= .elapsed_seconds
   and .eta_seconds_remaining <= (.elapsed_seconds * 2 + 2)'
assert_jq "Case A: eta_completion_at is ISO-8601 UTC" "$A_STATUS" \
  '.eta_completion_at | type == "string" and test("'"$ISO_RE"'")'
assert_jq "Case A: eta_completion_at is at/after updated_at" "$A_STATUS" \
  '(.eta_completion_at | fromdateiso8601) >= (.updated_at | fromdateiso8601)'

# --- Case B: running, 0 completed -> ETA null, elapsed populated -----------
CASE_B="$STATUS_TEST_TMPDIR/eta-running-zero"
build_case "$CASE_B" "2026-01-02T03:04:05Z" $'a/x\na/y\na/z\n' ''
write_case "$CASE_B" "running"
B_STATUS="$CASE_B/status.json"
assert_jq "Case B: elapsed_seconds populated when nothing completed" "$B_STATUS" \
  '.elapsed_seconds | type == "number" and . > 0'
assert_jq "Case B: eta_seconds_remaining present and null when completed == 0" "$B_STATUS" \
  'has("eta_seconds_remaining") and .eta_seconds_remaining == null'
assert_jq "Case B: eta_completion_at present and null when completed == 0" "$B_STATUS" \
  'has("eta_completion_at") and .eta_completion_at == null'

# --- Case C: terminal state -> ETA null, elapsed populated, no crash -------
CASE_C="$STATUS_TEST_TMPDIR/eta-terminal"
build_case "$CASE_C" "2026-01-02T03:04:05Z" $'a/x\na/y\na/z\n' $'a/x\na/y\na/z\n'
if write_case "$CASE_C" "finished"; then
  assert_eq "Case C: terminal snapshot write succeeds (no crash)" "0" "0"
else
  assert_eq "Case C: terminal snapshot write succeeds (no crash)" "0" "1"
fi
C_STATUS="$CASE_C/status.json"
assert_jq "Case C: elapsed_seconds populated on terminal state" "$C_STATUS" \
  '.elapsed_seconds | type == "number"'
assert_jq "Case C: eta_seconds_remaining null on terminal state (all lenses done)" "$C_STATUS" \
  'has("eta_seconds_remaining") and .eta_seconds_remaining == null'
assert_jq "Case C: eta_completion_at null on terminal state" "$C_STATUS" \
  'has("eta_completion_at") and .eta_completion_at == null'

# --- Case D: clock skew (started_at in the future) -> elapsed clamped to 0 --
CASE_D="$STATUS_TEST_TMPDIR/eta-clock-skew"
build_case "$CASE_D" "2099-01-01T00:00:00Z" $'a/x\na/y\na/z\n' ''
write_case "$CASE_D" "running"
D_STATUS="$CASE_D/status.json"
assert_jq "Case D: elapsed_seconds clamps to 0 (never negative) on clock skew" "$D_STATUS" \
  '.elapsed_seconds == 0'

# --- Case E: running, all lenses completed (transient) -> eta == 0 ----------
# (total - completed) == 0 while still running: distinct from Case B (null,
# completed == 0) and Case C (null, terminal). The zero-numerator branch must
# yield a numeric 0 and a real eta_completion_at ~ now, not null.
CASE_E="$STATUS_TEST_TMPDIR/eta-running-all-done"
build_case "$CASE_E" "2026-01-02T03:04:05Z" $'a/x\na/y\na/z\n' $'a/x\na/y\na/z\n'
write_case "$CASE_E" "running"
E_STATUS="$CASE_E/status.json"
assert_jq "Case E: elapsed_seconds populated when all lenses done" "$E_STATUS" \
  '.elapsed_seconds | type == "number" and . > 0'
assert_jq "Case E: eta_seconds_remaining is numeric 0 (not null) when total==completed" "$E_STATUS" \
  '.eta_seconds_remaining == 0'
assert_jq "Case E: eta_completion_at is a non-null ISO-8601 timestamp (~now)" "$E_STATUS" \
  '.eta_completion_at | type == "string" and test("'"$ISO_RE"'")'
assert_jq "Case E: eta_completion_at is within 2s of updated_at (eta == 0)" "$E_STATUS" \
  '((.eta_completion_at | fromdateiso8601) - (.updated_at | fromdateiso8601))
   | (if . < 0 then -. else . end) <= 2'

# --- Case F: running, 2 of 3 completed -> fractional rate, eta < elapsed -----
# Pins the division+floor for a ratio < 1: (3-2)/2 == 0.5, so eta must equal
# floor(elapsed/2). Case A only exercises the integer 2x multiplier and asserts
# eta >= elapsed, which would REJECT a correct fractional result -- so this path
# is genuinely uncovered.
CASE_F="$STATUS_TEST_TMPDIR/eta-running-fractional"
build_case "$CASE_F" "2026-01-02T03:04:05Z" $'a/x\na/y\na/z\n' $'a/x\na/y\n'
write_case "$CASE_F" "running"
F_STATUS="$CASE_F/status.json"
assert_jq "Case F: eta_seconds_remaining is a positive integer" "$F_STATUS" \
  '.eta_seconds_remaining | type == "number" and . > 0 and . == (. | floor)'
assert_jq "Case F: eta == floor(elapsed/2) for 2/3 completed (0.5x rate)" "$F_STATUS" \
  '.eta_seconds_remaining == ((.elapsed_seconds / 2) | floor)'
assert_jq "Case F: eta < elapsed when more than half the lenses are done" "$F_STATUS" \
  '.eta_seconds_remaining < .elapsed_seconds'

# --- Case G: rate-limit-pending with completions -> eta null, elapsed kept ---
# A non-running, non-terminal state that HAS completions: the gate is exactly
# state == "running", so eta must be null even though completed > 0. Also
# confirms the new fields coexist with the rate-limit-pending code path.
CASE_G="$STATUS_TEST_TMPDIR/eta-rate-limit-pending"
build_case "$CASE_G" "2026-01-02T03:04:05Z" $'a/x\na/y\na/z\n' $'a/x\n'
write_case "$CASE_G" "rate-limit-pending"
G_STATUS="$CASE_G/status.json"
assert_jq "Case G: state is rate-limit-pending" "$G_STATUS" \
  '.state == "rate-limit-pending"'
assert_jq "Case G: elapsed_seconds populated while paused" "$G_STATUS" \
  '.elapsed_seconds | type == "number" and . > 0'
assert_jq "Case G: eta_seconds_remaining null for non-running state despite completions" "$G_STATUS" \
  'has("eta_seconds_remaining") and .eta_seconds_remaining == null'
assert_jq "Case G: eta_completion_at null for non-running state" "$G_STATUS" \
  'has("eta_completion_at") and .eta_completion_at == null'

status_finish
