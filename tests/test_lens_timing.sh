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

# Tests for issue #337: per-lens start/end/duration timing in summary.json.
#
# record_lens / _record_lens_locked (lib/summary.sh) must persist three new
# fields on each lens object:
#   started_at        — ISO-8601 UTC string (null for legacy/skipped callers)
#   completed_at      — ISO-8601 UTC string (null for legacy/skipped callers)
#   duration_seconds  — non-negative integer (0 when absent or invalid)
#
# The change is additive and backward-compatible: existing 7-arg callers (the
# skipped-lens path at lib/rounds.sh:2189, the concurrency regression test for
# issue #221, etc.) must keep working with the new fields defaulting to null/0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=../lib/summary.sh
source "$SCRIPT_DIR/lib/summary.sh"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $(echo "$expected" | head -3)"
    echo "    Actual:   $(echo "$actual" | head -3)"
  fi
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== summary.json per-lens timing (issue #337) ==="

# =====================================================================
# Test 1: timing fields land verbatim for a fully-specified call
#   record_lens <file> <domain> <lens> <iters> <status> \
#               <issues> <rate_limit_sleep> <started_at> <completed_at> <duration>
# =====================================================================
echo ""
echo "Test 1: record_lens — started_at/completed_at/duration_seconds persist"
F1="$TMPDIR/summary-fields.json"
init_summary "$F1" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F1" "security" "injection" 3 "completed" 2 0 \
  "2026-06-27T10:00:00Z" "2026-06-27T10:05:00Z" 300

started_val="$(jq -r '.lenses[0].started_at' "$F1")"
assert_eq "started_at stored verbatim" "2026-06-27T10:00:00Z" "$started_val"
completed_val="$(jq -r '.lenses[0].completed_at' "$F1")"
assert_eq "completed_at stored verbatim" "2026-06-27T10:05:00Z" "$completed_val"
duration_val="$(jq '.lenses[0].duration_seconds' "$F1")"
assert_eq "duration_seconds stored as integer" "300" "$duration_val"

# Existing fields on the same lens object must remain intact (no regression).
issues_val="$(jq '.lenses[0].issues_created' "$F1")"
assert_eq "issues_created still recorded alongside timing" "2" "$issues_val"

# =====================================================================
# Test 2: backward-compat — legacy 7-arg call still works, timing defaults
#   to null/0. (Acceptance: record_lens callable with the old arg count.)
# =====================================================================
echo ""
echo "Test 2: record_lens — legacy 7-arg call defaults timing to null/0"
F2="$TMPDIR/summary-legacy.json"
init_summary "$F2" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F2" "security" "xss" 1 "completed" 1 0
legacy_rc=$?
assert_eq "legacy 7-arg call exits 0" "0" "$legacy_rc"
started_val="$(jq '.lenses[0].started_at' "$F2")"
assert_eq "started_at defaults to null for legacy caller" "null" "$started_val"
completed_val="$(jq '.lenses[0].completed_at' "$F2")"
assert_eq "completed_at defaults to null for legacy caller" "null" "$completed_val"
duration_val="$(jq '.lenses[0].duration_seconds' "$F2")"
assert_eq "duration_seconds defaults to 0 for legacy caller" "0" "$duration_val"

# =====================================================================
# Test 3: skipped-lens path — timing null/0 and lenses_run NOT incremented.
#   Mirrors the 7-arg skipped call at lib/rounds.sh:2189.
# =====================================================================
echo ""
echo "Test 3: record_lens — skipped lens keeps null timing and lenses_run"
F3="$TMPDIR/summary-skipped.json"
init_summary "$F3" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F3" "security" "csrf" 0 "skipped" 0 0
started_val="$(jq '.lenses[0].started_at' "$F3")"
assert_eq "skipped lens started_at is null" "null" "$started_val"
duration_val="$(jq '.lenses[0].duration_seconds' "$F3")"
assert_eq "skipped lens duration_seconds is 0" "0" "$duration_val"
run_val="$(jq '.totals.lenses_run' "$F3")"
assert_eq "skipped lens does not increment lenses_run" "0" "$run_val"

# =====================================================================
# Test 4: invalid duration_seconds coerces to 0, mirroring the existing
#   rate_limit_sleep_seconds integer-validation behavior.
# =====================================================================
echo ""
echo "Test 4: record_lens — non-numeric duration_seconds coerces to 0"
F4="$TMPDIR/summary-invalid.json"
init_summary "$F4" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F4" "security" "bad-duration" 1 "completed" 0 0 "" "" "not-a-number"
invalid_rc=$?
assert_eq "invalid-duration call exits 0" "0" "$invalid_rc"
duration_val="$(jq '.lenses[0].duration_seconds' "$F4")"
assert_eq "non-numeric duration_seconds coerces to 0" "0" "$duration_val"

# =====================================================================
# Test 5: negative duration_seconds coerces to 0. This is the realistic
#   defensive case (a backward NTP clock step mid-lens yields end < start);
#   the ^[0-9]+$ guard rejects the leading '-', mirroring run_lens's own clamp.
#   Distinct from Test 4 ("not-a-number" — non-digit garbage).
# =====================================================================
echo ""
echo "Test 5: record_lens — negative duration_seconds coerces to 0"
F5="$TMPDIR/summary-negative.json"
init_summary "$F5" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F5" "security" "ntp-step" 1 "completed" 0 0 \
  "2026-06-27T10:00:00Z" "2026-06-27T09:59:50Z" -10
neg_rc=$?
assert_eq "negative-duration call exits 0" "0" "$neg_rc"
duration_val="$(jq '.lenses[0].duration_seconds' "$F5")"
assert_eq "negative duration_seconds coerces to 0" "0" "$duration_val"

# =====================================================================
# Test 6: per-field empty→null mapping. An explicitly-passed empty string for
#   one timestamp must map to JSON null while a set timestamp on the same
#   lens object is preserved verbatim — exercising the per-field
#   `($x | if . == "" then null else . end)` branch independently.
# =====================================================================
echo ""
echo "Test 6: record_lens — explicit empty timestamp maps to null per-field"
F6="$TMPDIR/summary-partial.json"
init_summary "$F6" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F6" "security" "partial-ts" 1 "completed" 0 0 \
  "2026-06-27T10:00:00Z" "" 5
started_val="$(jq -r '.lenses[0].started_at' "$F6")"
assert_eq "set started_at preserved when completed_at empty" "2026-06-27T10:00:00Z" "$started_val"
completed_val="$(jq '.lenses[0].completed_at' "$F6")"
assert_eq "explicit-empty completed_at maps to null" "null" "$completed_val"
duration_val="$(jq '.lenses[0].duration_seconds' "$F6")"
assert_eq "duration_seconds still recorded with one empty timestamp" "5" "$duration_val"

# =====================================================================
# Test 7: multiple lenses each retain their own timing — the additive append
#   does not cross-contaminate. A timed lens followed by a legacy 7-arg lens
#   in the SAME file must keep distinct timing on each object.
# =====================================================================
echo ""
echo "Test 7: record_lens — multiple lenses retain independent timing"
F7="$TMPDIR/summary-multi.json"
init_summary "$F7" "test-run" "/tmp/project" "audit" "claude" "" ""
record_lens "$F7" "security" "first" 2 "completed" 1 0 \
  "2026-06-27T10:00:00Z" "2026-06-27T10:02:00Z" 120
record_lens "$F7" "security" "second" 1 "completed" 0 0   # legacy 7-arg → null/0
lens_count="$(jq '.lenses | length' "$F7")"
assert_eq "both lenses appended" "2" "$lens_count"
first_dur="$(jq '.lenses[0].duration_seconds' "$F7")"
assert_eq "first lens keeps its duration" "120" "$first_dur"
first_started="$(jq -r '.lenses[0].started_at' "$F7")"
assert_eq "first lens keeps its started_at" "2026-06-27T10:00:00Z" "$first_started"
second_dur="$(jq '.lenses[1].duration_seconds' "$F7")"
assert_eq "second (legacy) lens duration defaults to 0" "0" "$second_dur"
second_started="$(jq '.lenses[1].started_at' "$F7")"
assert_eq "second (legacy) lens started_at defaults to null" "null" "$second_started"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
