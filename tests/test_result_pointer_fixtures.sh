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

# Smoke test for the shared result-pointer fixtures harness (issue #318).
#
# This is the ONE test the harness issue ships: it proves the shared lib
# (tests/result_pointer_test_lib.sh) actually works end-to-end without a model.
# It does NOT re-cover the per-feature assertions owned by the sibling issues
# (#308/#310/#312/#313) — those add their own. Here we only assert that:
#
#   AC#1 isolation  — the tree is built in a /tmp farm OUTSIDE the repo, and the
#                     real repo logs/latest-result.json is byte-for-byte unchanged.
#   AC#2 shapes     — the canonical run dirs are present with the expected shapes
#                     (current+manifest, incomplete+sentinel, status-only empty,
#                     prior+manifest, non-run issues/).
#   AC#3 wiring     — write_latest_result_pointer is callable against the farm
#                     (pure fixtures: NO repolens.sh run, NO agent).
#   AC#4 counts     — manifest_with_severities.json flows through
#                     severity_normalize into headline counts.
#   AC#5 discarded  — the three sibling runs are classified with the expected
#                     reasons and the current/non-run dirs are excluded.

set -uo pipefail

# shellcheck disable=SC1091
# shellcheck source=tests/result_pointer_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/result_pointer_test_lib.sh"

trap rp_cleanup EXIT

rp_require_jq

echo "=== result-pointer fixtures harness smoke test (issue #318) ==="

# Snapshot the real repo pointer BEFORE touching anything, so we can prove at the
# end that building/driving the farm never wrote to the real logs/ (AC#1). logs/
# is gitignored runtime, so it may or may not already hold a pointer — we assert
# UNCHANGED, not absent.
REAL_POINTER="$RP_TEST_ROOT/logs/latest-result.json"
real_before="(absent)"
[[ -f "$REAL_POINTER" ]] && real_before="$(cksum < "$REAL_POINTER")"

rp_setup_farm
rp_build_tree "$RP_TEST_LOGS"

# The farm logs dir must live OUTSIDE the repo tree (mktemp -> /tmp), the core of
# the isolation guarantee.
TOTAL=$((TOTAL + 1))
case "$RP_TEST_LOGS" in
  "$RP_TEST_ROOT"/*) record_fail "farm logs/ is outside the repo tree" "RP_TEST_LOGS=$RP_TEST_LOGS is under the repo root" ;;
  *)                 record_pass "farm logs/ is outside the repo tree" ;;
esac

# --- AC#2: run-dir shapes ---------------------------------------------------
CUR_DIR="$RP_TEST_LOGS/$RP_RUN_CURRENT"
INC_DIR="$RP_TEST_LOGS/$RP_RUN_INCOMPLETE"
EMP_DIR="$RP_TEST_LOGS/$RP_RUN_EMPTY"
PRI_DIR="$RP_TEST_LOGS/$RP_RUN_PRIOR"

assert_file_exists "current run has summary.json" "$CUR_DIR/summary.json"
assert_file_exists "current run has final/manifest.json" "$CUR_DIR/final/manifest.json"
assert_file_exists "incomplete run has .rate-limit-abort sentinel" "$INC_DIR/.rate-limit-abort"
assert_file_exists "empty run has status.json" "$EMP_DIR/status.json"
assert_absent "empty run has NO summary.json" "$EMP_DIR/summary.json"
assert_absent "empty run has NO final/manifest.json" "$EMP_DIR/final/manifest.json"
assert_file_exists "prior run has final/manifest.json" "$PRI_DIR/final/manifest.json"
assert_present "non-run issues/ dir present" "$RP_TEST_LOGS/issues"

# issues/ must NOT be run-id-shaped (the regex is what excludes it).
TOTAL=$((TOTAL + 1))
# shellcheck disable=SC2050 # Intentional: assert the literal non-run dir name does not match the run-id regex.
if [[ "issues" =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$ ]]; then
  record_fail "non-run issues/ dir is not run-id-shaped" "'issues' unexpectedly matched the run-id regex"
else
  record_pass "non-run issues/ dir is not run-id-shaped"
fi

# --- AC#3: drive write_latest_result_pointer end-to-end (model-free) --------
rp_run_pointer "$RP_TEST_LOGS" "$RP_RUN_CURRENT" \
  "$CUR_DIR/summary.json" "finished" "$CUR_DIR/final"
rc=$?

POINTER="$RP_TEST_LOGS/latest-result.json"

assert_eq "write_latest_result_pointer returns 0 (non-fatal)" "0" "$rc"
assert_file_exists "latest-result.json written to the farm" "$POINTER"
assert_jq_true "latest-result.json is valid JSON" "$POINTER" '.'
assert_jq_eq "pointer run_id is the current run" "$POINTER" '.run_id' "$RP_RUN_CURRENT"

# --- AC#4: counts flow through severity_normalize ---------------------------
assert_jq_eq "counts.critical == 1" "$POINTER" '.counts.critical' "1"
assert_jq_eq "counts.high == 2 (high + HIGH)" "$POINTER" '.counts.high' "2"
assert_jq_eq "counts.medium == 1 ([Medium] bracket form)" "$POINTER" '.counts.medium' "1"
assert_jq_eq "counts.low == 1" "$POINTER" '.counts.low' "1"
assert_jq_true "counts drops the invalid 'info' severity" "$POINTER" '(.counts | has("info")) == false'

# --- AC#5: discarded_runs classification ------------------------------------
assert_jq_true "discarded_runs is an array" "$POINTER" '.discarded_runs | type == "array"'
assert_jq_eq "discarded_runs lists exactly 3 sibling runs" "$POINTER" '.discarded_runs | length' "3"
assert_jq_eq "incomplete run -> aborted-or-incomplete" "$POINTER" \
  ".discarded_runs[] | select(.run_id==\"$RP_RUN_INCOMPLETE\") | .reason" "aborted-or-incomplete"
assert_jq_eq "status-only run -> empty" "$POINTER" \
  ".discarded_runs[] | select(.run_id==\"$RP_RUN_EMPTY\") | .reason" "empty"
assert_jq_eq "prior complete run (has manifest) -> superseded" "$POINTER" \
  ".discarded_runs[] | select(.run_id==\"$RP_RUN_PRIOR\") | .reason" "superseded"
assert_jq_true "current run excluded from its own discarded_runs" "$POINTER" \
  "([.discarded_runs[].run_id] | index(\"$RP_RUN_CURRENT\")) == null"
assert_jq_true "non-run issues/ dir excluded from discarded_runs" "$POINTER" \
  '([.discarded_runs[].run_id] | index("issues")) == null'

# --- AC#1: the real repo logs/ was never touched ----------------------------
real_after="(absent)"
[[ -f "$REAL_POINTER" ]] && real_after="$(cksum < "$REAL_POINTER")"
assert_eq "real repo logs/latest-result.json unchanged (isolation)" "$real_before" "$real_after"

rp_finish
