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

# Tests for issue #357: add a startup wall-clock estimate helper.
#
# A new pure helper
#   estimate_run_wall_seconds <lens_count> <depth> <rounds> <max_parallel> [per_iter_secs]
# in lib/summary.sh returns an INTEGER seconds estimate on stdout using:
#   ceil(lens_count / max_parallel) * depth * rounds * per_iter_secs
# per_iter_secs defaults to 90, overridable via the env var
# REPOLENS_EST_PER_ITER_SECS or an explicit 5th argument. The helper does NO
# I/O and makes NO model calls — it is pure integer arithmetic, and the caller
# (a follow-up issue) is responsible for formatting/printing human text.
#
# Acceptance criteria exercised here:
#   AC1: estimate_run_wall_seconds 335 3 1 8 -> ceil(335/8)*3*1*90 = 11340
#        (a plausible positive integer).
#   AC2: max_parallel = 0 or empty must NOT divide-by-zero (treated as 1).
#   AC3: REPOLENS_EST_PER_ITER_SECS overrides the default per_iter_secs.
#   AC4: pure arithmetic — exactly one integer on stdout, exit 0, no stray text.
#
# These are BEHAVIORAL tests against the public helper signature described in the
# issue. They assert exact integers because the formula is fully specified, and
# they cover the documented guards (divide-by-zero, non-numeric, octal/leading
# zero, negatives, env vs. 5th-arg precedence). No real models — pure arithmetic.

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
    echo "    Expected: $(printf '%s' "$expected" | head -3)"
    echo "    Actual:   $(printf '%s' "$actual" | head -3)"
  fi
}

# yes/no: is $1 a single line of one-or-more decimal digits (a clean integer)?
is_int() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then echo "yes"; else echo "no"; fi
}

echo "=== estimate_run_wall_seconds (issue #357) ==="

# =====================================================================
# Test 1: AC1 headline — 335 lenses, depth 3, 1 round, 8-wide.
#   ceil(335/8) = 42 waves; 42 * 3 * 1 * 90 = 11340.
# =====================================================================
echo ""
echo "Test 1: headline AC (335 3 1 8) -> 11340"
out1="$(estimate_run_wall_seconds 335 3 1 8 2>/dev/null)"
assert_eq "335 3 1 8 = ceil(335/8)*3*1*90 = 11340" "11340" "$out1"
assert_eq "result is a positive integer"           "yes"   "$(is_int "$out1")"

# =====================================================================
# Test 2: ceil semantics on a partial final wave.
#   17 lenses / 8-wide = ceil(17/8) = 3 waves (NOT floor=2).
#   3 * 1 * 1 * 90 = 270. Floor would give 180 — this case discriminates.
# =====================================================================
echo ""
echo "Test 2: partial wave rounds UP (ceil, not floor)"
out2="$(estimate_run_wall_seconds 17 1 1 8 2>/dev/null)"
assert_eq "17 1 1 8 = ceil(17/8)=3 waves -> 270" "270" "$out2"

# =====================================================================
# Test 3: exact division leaves no partial wave.
#   16 / 8 = 2 waves exactly; 2 * 1 * 1 * 90 = 180.
# =====================================================================
echo ""
echo "Test 3: exact division (16 1 1 8) -> 180"
out3="$(estimate_run_wall_seconds 16 1 1 8 2>/dev/null)"
assert_eq "16 1 1 8 = 2 waves -> 180" "180" "$out3"

# =====================================================================
# Test 4: AC2 — max_parallel=0 must NOT divide-by-zero; treat as 1.
#   ceil(335/1) = 335; 335 * 3 * 1 * 90 = 90450. Must also exit 0.
# =====================================================================
echo ""
echo "Test 4: max_parallel=0 guard (no divide-by-zero)"
out4="$(estimate_run_wall_seconds 335 3 1 0 2>/dev/null)"
rc4=$?
assert_eq "max_parallel=0 treated as 1 -> 90450" "90450" "$out4"
assert_eq "exit status is 0 (did not error out)" "0"     "$rc4"

# =====================================================================
# Test 5: AC2 — empty max_parallel also treated as 1.
# =====================================================================
echo ""
echo "Test 5: empty max_parallel treated as 1"
out5="$(estimate_run_wall_seconds 335 3 1 "" 2>/dev/null)"
assert_eq "empty max_parallel -> 90450" "90450" "$out5"

# =====================================================================
# Test 6: AC3 — REPOLENS_EST_PER_ITER_SECS overrides the 90s default.
#   ceil(335/8)=42; 42 * 3 * 1 * 10 = 1260.
# =====================================================================
echo ""
echo "Test 6: env override REPOLENS_EST_PER_ITER_SECS=10"
out6="$(REPOLENS_EST_PER_ITER_SECS=10 estimate_run_wall_seconds 335 3 1 8 2>/dev/null)"
assert_eq "env per_iter=10 -> 42*3*1*10 = 1260" "1260" "$out6"

# =====================================================================
# Test 7: explicit 5th-arg per_iter_secs beats BOTH env and default.
#   With env=10 set but arg=30 passed: 42 * 3 * 1 * 30 = 3780.
# =====================================================================
echo ""
echo "Test 7: explicit 5th arg overrides env and default"
out7="$(REPOLENS_EST_PER_ITER_SECS=10 estimate_run_wall_seconds 335 3 1 8 30 2>/dev/null)"
assert_eq "arg per_iter=30 wins over env=10 -> 3780" "3780" "$out7"

# =====================================================================
# Test 8: non-numeric inputs fall back safely (do not crash, no garbage).
#   - all-garbage: lenses non-numeric -> 0 lenses -> 0 seconds.
#   - lenses ok, others garbage: depth/rounds/max_parallel each fall to 1,
#     so 100 abc abc abc = ceil(100/1)=100 * 1 * 1 * 90 = 9000.
# =====================================================================
echo ""
echo "Test 8: non-numeric inputs use safe fallbacks"
out8a="$(estimate_run_wall_seconds abc x y z 2>/dev/null)"
rc8a=$?
assert_eq "all-garbage -> lens_count 0 -> 0"        "0"    "$out8a"
assert_eq "all-garbage still exits 0"               "0"    "$rc8a"
out8b="$(estimate_run_wall_seconds 100 abc abc abc 2>/dev/null)"
assert_eq "100 abc abc abc -> depth/rounds/par=1 -> 9000" "9000" "$out8b"

# =====================================================================
# Test 9: zero lenses is genuinely zero work (lens_count is NOT clamped to 1).
# =====================================================================
echo ""
echo "Test 9: zero lenses -> 0 seconds"
out9="$(estimate_run_wall_seconds 0 3 2 8 2>/dev/null)"
assert_eq "0 lenses -> 0 seconds" "0" "$out9"

# =====================================================================
# Test 10: serial run (max_parallel=1) — every lens is its own wave.
#   335 * 3 * 1 * 90 = 90450.
# =====================================================================
echo ""
echo "Test 10: serial max_parallel=1"
out10="$(estimate_run_wall_seconds 335 3 1 1 2>/dev/null)"
assert_eq "335 3 1 1 -> 90450" "90450" "$out10"

# =====================================================================
# Test 11: leading-zero / octal-looking operand must NOT crash.
#   "08" is invalid octal under bash $(( )); the helper must parse it base-10.
#   335 3 1 08 == 335 3 1 8 -> 11340, exit 0.
# =====================================================================
echo ""
echo "Test 11: leading-zero operand parsed base-10 (no octal crash)"
out11="$(estimate_run_wall_seconds 335 3 1 08 2>/dev/null)"
rc11=$?
assert_eq "08 parsed as 8 -> 11340" "11340" "$out11"
assert_eq "no error on octal-looking input (exit 0)" "0" "$rc11"

# =====================================================================
# Test 12: negative max_parallel is rejected by the numeric guard -> treated
#   as 1 (the leading '-' fails the ^[0-9]+$ check). 335 3 1 -4 -> 90450.
# =====================================================================
echo ""
echo "Test 12: negative max_parallel falls back to 1"
out12="$(estimate_run_wall_seconds 335 3 1 -4 2>/dev/null)"
assert_eq "negative max_parallel -> 90450" "90450" "$out12"

# =====================================================================
# Test 13: AC4 — pure arithmetic: stdout is EXACTLY one integer, exit 0, and
#   nothing is written to stderr in the happy path (clean $(...) capture).
# =====================================================================
echo ""
echo "Test 13: clean single-integer stdout, no stderr, exit 0"
err13="$(estimate_run_wall_seconds 335 3 1 8 2>&1 1>/dev/null)"
out13="$(estimate_run_wall_seconds 335 3 1 8 2>/dev/null)"
rc13=$?
assert_eq "stdout is a single clean integer"  "yes" "$(is_int "$out13")"
assert_eq "no stderr output in happy path"    ""    "$err13"
assert_eq "exit status 0"                     "0"   "$rc13"

# =====================================================================
# Test 14: a NON-NUMERIC env var falls back to the default 90.
#   This is the ONLY way to reach the second validation line
#     [[ "$per_iter" =~ ^[0-9]+$ ]] || per_iter=90
#   A numeric env (Test 6/7) passes both checks; an empty/missing env yields
#   90 via ${REPOLENS_EST_PER_ITER_SECS:-90}, NOT via this `|| per_iter=90`.
#   So only a garbage env value exercises this guard. 42*3*1*90 = 11340.
#   Must also stay pure: clean integer, no stderr, exit 0.
# =====================================================================
echo ""
echo "Test 14: non-numeric env var falls back to default 90"
out14="$(REPOLENS_EST_PER_ITER_SECS=abc estimate_run_wall_seconds 335 3 1 8 2>/dev/null)"
rc14=$?
err14="$(REPOLENS_EST_PER_ITER_SECS=abc estimate_run_wall_seconds 335 3 1 8 2>&1 1>/dev/null)"
assert_eq "garbage env -> default 90 -> 11340"     "11340" "$out14"
assert_eq "garbage env still exits 0"              "0"     "$rc14"
assert_eq "garbage env writes nothing to stderr"   ""      "$err14"

# =====================================================================
# Test 15: a PRESENT-but-non-numeric 5th arg is ignored; precedence falls
#   through to the env (then to the default if env is unset). Existing tests
#   only pass empty (Tests 1-6) or valid (Test 7) 5th args, so the
#   `if [[ ! "$per_iter" =~ ^[0-9]+$ ]]` true-branch is never exercised by a
#   garbage explicit arg.
#     - with env=10: garbage arg ignored -> env 10 -> 42*3*1*10 = 1260.
#     - no env:      garbage arg ignored -> default 90 -> 11340.
# =====================================================================
echo ""
echo "Test 15: non-numeric 5th arg falls back (to env, then default)"
out15a="$(REPOLENS_EST_PER_ITER_SECS=10 estimate_run_wall_seconds 335 3 1 8 abc 2>/dev/null)"
assert_eq "garbage 5th arg + env=10 -> 1260"   "1260"  "$out15a"
out15b="$(estimate_run_wall_seconds 335 3 1 8 abc 2>/dev/null)"
assert_eq "garbage 5th arg + no env -> 11340"  "11340" "$out15b"

# =====================================================================
# Test 16: a valid explicit 5th arg beats the bare default with NO env set.
#   Test 7 proves arg > env, but env=10 is set there, so it never isolates
#   arg > default. Here: no env, arg=30 -> 42*3*1*30 = 3780 (not the 90-based
#   11340). Discriminates the explicit-arg path from the default path.
# =====================================================================
echo ""
echo "Test 16: explicit 5th arg overrides the default (no env set)"
out16="$(estimate_run_wall_seconds 335 3 1 8 30 2>/dev/null)"
assert_eq "arg per_iter=30 (no env) -> 3780" "3780" "$out16"

# =====================================================================
# Test 17: leading-zero / octal-looking per_iter is parsed base-10, both as
#   the 5th arg and via the env var. Test 11 only proves 10# on max_parallel
#   (the divisor `p`); per_iter is a SEPARATE $(( )) operand (`s`). "08" must
#   become 8, not crash as invalid octal. 42*3*1*8 = 1008, exit 0.
# =====================================================================
echo ""
echo "Test 17: octal-looking per_iter parsed base-10 (arg and env)"
out17a="$(estimate_run_wall_seconds 335 3 1 8 08 2>/dev/null)"
rc17a=$?
assert_eq "5th arg 08 parsed as 8 -> 1008"      "1008" "$out17a"
assert_eq "octal 5th arg does not error (exit 0)" "0"  "$rc17a"
out17b="$(REPOLENS_EST_PER_ITER_SECS=08 estimate_run_wall_seconds 335 3 1 8 2>/dev/null)"
assert_eq "env 08 parsed as 8 -> 1008"          "1008" "$out17b"

# =====================================================================
# Test 18: leading-zero / octal-looking lens_count (the ceil DIVIDEND `n`) is
#   parsed base-10. Test 11 only covers the divisor; this locks 10# on the
#   dividend operand too. 016 -> 16; ceil(16/8)=2 -> 2*1*1*90 = 180, exit 0.
# =====================================================================
echo ""
echo "Test 18: octal-looking lens_count parsed base-10"
out18="$(estimate_run_wall_seconds 016 1 1 8 2>/dev/null)"
rc18=$?
assert_eq "016 lenses parsed as 16 -> 180" "180" "$out18"
assert_eq "octal lens_count exits 0"       "0"   "$rc18"

# =====================================================================
# Test 19: an env var set to the EMPTY string (set, not unset) yields the
#   default 90 via the ${REPOLENS_EST_PER_ITER_SECS:-90} `:-` expansion (which
#   treats empty the same as unset). Distinct from Test 14's non-empty garbage.
#   42*3*1*90 = 11340.
# =====================================================================
echo ""
echo "Test 19: empty-but-set env var falls back to default 90"
out19="$(REPOLENS_EST_PER_ITER_SECS="" estimate_run_wall_seconds 335 3 1 8 2>/dev/null)"
assert_eq "empty env -> default 90 -> 11340" "11340" "$out19"

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
