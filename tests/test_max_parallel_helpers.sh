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

# Unit tests for issue #367 — the two pure max-parallel resolution helpers in
# lib/parallel.sh:
#
#   detect_nproc                       -> host core count, REPOLENS_NPROC-pinnable
#   repolens_auto_max_parallel <cores> -> clamp(cores, FLOOR=8, CAP=32)
#
# WHY THIS FILE EXISTS (the gap it fills):
# The behavioral suite (tests/test_max_parallel_default.sh) drives the resolution
# rule end-to-end through `repolens.sh --dry-run` and the wall-clock preview line.
# That path can only ever feed the clamp a CLEAN base-10 integer, because
# detect_nproc always normalizes its output before the clamp sees it. As a result
# the clamp's defensive non-numeric/empty/zero guard
# (`[[ "$cores" =~ ^[0-9]+$ ]] || cores=0`) and its exact off-by-one boundaries are
# UNREACHABLE from the CLI surface — removing that guard, or flipping a `<`/`>` to
# `<=`/`>=`, would leave the behavioral suite green while silently changing or
# crashing the helper. Likewise the CLI suite never exercises REPOLENS_NPROC=0 nor
# isolates detect_nproc's base-10 parse (08 collapses to the floor either way), so
# octal-vs-base-10 in detect_nproc is invisible there. These unit tests source the
# lib directly and exercise both pure functions across their real branch matrix.
#
# The test-dev stage deliberately skipped direct unit tests of these helpers
# because their names/home module were not yet fixed; the implementation has now
# fixed them in lib/parallel.sh, so this coverage stage fills them.
#
# NO AI models are invoked — the lib is sourced and the pure functions are called
# directly. Nothing here spawns an agent or repolens.sh subprocess.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# detect_nproc reads ${REPOLENS_NPROC:-} from the environment; scrub any host /
# CI-injected pin so only the per-test temporary assignments below are in effect.
unset REPOLENS_NPROC

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"

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
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

# assert_positive_int DESC VALUE — VALUE matches ^[0-9]+$ and is >= 1.
assert_positive_int() {
  local desc="$1" value="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )); then
    PASS=$((PASS + 1))
    echo "  PASS: $desc (value=$value)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected a positive int, got '$value')"
  fi
}

echo ""
echo "=== Test Suite: max-parallel pure helpers (issue #367) ==="
echo ""

# ---------------------------------------------------------------------------
# repolens_auto_max_parallel — clamp(cores, FLOOR=8, CAP=32)
#
# Boundary grid (incl. the floor-1/floor/floor+1 and cap-1/cap/cap+1 off-by-one
# cases the CLI suite does NOT probe): a `<`→`<=` or `>`→`>=` slip in the clamp
# is caught here.
# ---------------------------------------------------------------------------
echo "Test 1: clamp boundary grid (floor=8, cap=32, off-by-one neighbors)"
assert_eq "clamp(1)  -> 8  (well below floor)"      "8"  "$(repolens_auto_max_parallel 1)"
assert_eq "clamp(7)  -> 8  (floor - 1)"             "8"  "$(repolens_auto_max_parallel 7)"
assert_eq "clamp(8)  -> 8  (floor, inclusive)"      "8"  "$(repolens_auto_max_parallel 8)"
assert_eq "clamp(9)  -> 9  (floor + 1, pass-thru)"  "9"  "$(repolens_auto_max_parallel 9)"
assert_eq "clamp(16) -> 16 (mid-band pass-thru)"    "16" "$(repolens_auto_max_parallel 16)"
assert_eq "clamp(31) -> 31 (cap - 1, pass-thru)"    "31" "$(repolens_auto_max_parallel 31)"
assert_eq "clamp(32) -> 32 (cap, inclusive)"        "32" "$(repolens_auto_max_parallel 32)"
assert_eq "clamp(33) -> 32 (cap + 1, clamped)"      "32" "$(repolens_auto_max_parallel 33)"
assert_eq "clamp(64) -> 32 (well above cap)"        "32" "$(repolens_auto_max_parallel 64)"

# ---------------------------------------------------------------------------
# repolens_auto_max_parallel — defensive guard for non-integer / empty / zero
# input. UNREACHABLE via the CLI (detect_nproc always hands the clamp a clean
# integer), so this is the only place the `|| cores=0` guard is exercised. Each
# of these must collapse to the FLOOR without a `set -u` crash on $((10#$cores)).
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: clamp defensive guard — garbage / empty / zero collapse to floor 8"
assert_eq "clamp('')      -> 8 (empty input)"           "8" "$(repolens_auto_max_parallel '')"
assert_eq "clamp(0)       -> 8 (zero is not valid)"     "8" "$(repolens_auto_max_parallel 0)"
assert_eq "clamp('abc')   -> 8 (non-numeric)"           "8" "$(repolens_auto_max_parallel abc)"
assert_eq "clamp('-5')    -> 8 (negative rejected)"     "8" "$(repolens_auto_max_parallel -5)"
assert_eq "clamp('12abc') -> 8 (mixed token rejected)"  "8" "$(repolens_auto_max_parallel 12abc)"
# No-arg call: ${1:-} is empty -> floor. Locks the set -u-safe default.
assert_eq "clamp()        -> 8 (no argument at all)"    "8" "$(repolens_auto_max_parallel)"

# ---------------------------------------------------------------------------
# repolens_auto_max_parallel — base-10 parsing: a zero-padded value must not be
# read as octal. clamp('08') would be an octal error under $((08)); base-10
# parsing makes it 8 -> floor.
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: clamp parses base-10 (zero-padded input is not octal)"
assert_eq "clamp('08') -> 8  (08 base-10 = 8, then floor)"   "8"  "$(repolens_auto_max_parallel 08)"
assert_eq "clamp('020') -> 20 (020 base-10 = 20, NOT octal 16)" "20" "$(repolens_auto_max_parallel 020)"

# ---------------------------------------------------------------------------
# detect_nproc — the REPOLENS_NPROC pin is honored verbatim (pre-clamp), parsed
# base-10. This is the raw detector output, BEFORE the clamp, so it can return
# values outside [8,32] (the clamp is a separate function). The bash temporary
# assignment `VAR=val func` scopes the pin to the single call.
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: detect_nproc honors the REPOLENS_NPROC pin (pre-clamp, base-10)"
assert_eq "REPOLENS_NPROC=16 -> 16 (verbatim, in-band)"        "16" "$(REPOLENS_NPROC=16 detect_nproc)"
assert_eq "REPOLENS_NPROC=64 -> 64 (verbatim, NOT yet capped)" "64" "$(REPOLENS_NPROC=64 detect_nproc)"
assert_eq "REPOLENS_NPROC=0  -> 0  (zero passes through pre-clamp)" "0" "$(REPOLENS_NPROC=0 detect_nproc)"
assert_eq "REPOLENS_NPROC=016 -> 16 (base-10, NOT octal 14)"   "16" "$(REPOLENS_NPROC=016 detect_nproc)"
assert_eq "REPOLENS_NPROC=08 -> 8 (base-10, not an octal error)" "8" "$(REPOLENS_NPROC=08 detect_nproc)"

# ---------------------------------------------------------------------------
# detect_nproc — a non-numeric / empty pin must fall through the resolution
# chain (nproc -> getconf -> floor 8) and yield a positive integer WITHOUT
# crashing under `set -uo pipefail`. We assert exit 0 and a positive int rather
# than an exact value, so the test stays host-independent.
# ---------------------------------------------------------------------------
echo ""
echo "Test 5: detect_nproc falls back safely on a non-numeric/empty/unset pin"
garbage_out="$(REPOLENS_NPROC=not-a-number detect_nproc)"; garbage_rc=$?
assert_eq "garbage pin exits 0 (no set -u crash)" "0" "$garbage_rc"
assert_positive_int "garbage pin falls back to a positive int" "$garbage_out"

empty_out="$(REPOLENS_NPROC='' detect_nproc)"; empty_rc=$?
assert_eq "empty pin exits 0" "0" "$empty_rc"
assert_positive_int "empty pin falls back to a positive int" "$empty_out"

# Unset entirely (subshell so the scrub does not leak back): real host detection.
unset_out="$( ( unset REPOLENS_NPROC 2>/dev/null; detect_nproc ) )"; unset_rc=$?
assert_eq "unset pin exits 0" "0" "$unset_rc"
assert_positive_int "unset pin returns the real detected core count (positive int)" "$unset_out"

# ---------------------------------------------------------------------------
# Composition — the exact wiring repolens.sh uses to resolve the auto-default:
#   MAX_PARALLEL = repolens_auto_max_parallel "$(detect_nproc)"
# This locks the end-to-end mapping the CLI suite leaves untested, most notably
# the zero-cores edge (REPOLENS_NPROC=0): detect_nproc returns 0, the clamp
# floors it to 8. A many-core pin caps at 32; a mid pin passes through.
# ---------------------------------------------------------------------------
echo ""
echo "Test 6: composed resolution detect_nproc | clamp (incl. zero-cores edge)"
assert_eq "NPROC=0  composed -> 8  (zero cores floored; CLI never tests this)" \
          "8"  "$(repolens_auto_max_parallel "$(REPOLENS_NPROC=0 detect_nproc)")"
assert_eq "NPROC=2  composed -> 8  (sub-floor floored)" \
          "8"  "$(repolens_auto_max_parallel "$(REPOLENS_NPROC=2 detect_nproc)")"
assert_eq "NPROC=16 composed -> 16 (mid pass-thru)" \
          "16" "$(repolens_auto_max_parallel "$(REPOLENS_NPROC=16 detect_nproc)")"
assert_eq "NPROC=64 composed -> 32 (capped)" \
          "32" "$(repolens_auto_max_parallel "$(REPOLENS_NPROC=64 detect_nproc)")"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
