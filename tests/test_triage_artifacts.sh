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

# Integration test for issue #351: feed ONE shared, handwritten registry fixture
# to ALL FOUR human-triage generators (generate_todo_md / generate_summary_md /
# generate_needs_review_md / generate_duplicates_md in lib/artifacts.sh) and
# assert the CROSS-ARTIFACT routing contract end to end. The four sibling
# test_artifact_*.sh files pin each generator's micro-behavior in isolation; this
# file proves that one registry PARTITIONS correctly across all four at once —
# nothing lost, nothing double-counted beyond the one intentional TODO/NEEDS_REVIEW
# overlap (a status=new, high-confidence finding that also needs an external
# scanner appears in BOTH lists by design).
#
# Pure-function test: NO AI model is invoked. The generators are pure jq+bash and
# the input is a committed, byte-deterministic JSON-Lines fixture
# (tests/fixtures/triage-findings/findings.jsonl). We never run repolens.sh (it
# spawns real agents). The fixture is READ-ONLY input; only the generated
# final/*.md land in a temp dir cleaned up on EXIT.
#
# The fixture (see that file) is built so the cross-artifact routing is
# unambiguous and the SUMMARY 20-cap boundary is deterministic:
#   - F01..F03  -> TODO.md         (status=new, not low-confidence)
#   - F10..F14  -> NEEDS_REVIEW.md (one record per predicate P1..P5)
#   - F13       -> TODO.md AND NEEDS_REVIEW.md (the INTENTIONAL overlap: P4)
#   - F12       -> NEEDS_REVIEW only (status=new but confidence 0.3 < 0.5)
#   - F20       -> DUPLICATES.md   (canonical with a 2-element also_reported_by)
#   - F21       -> singleton, excluded from DUPLICATES.md
#   - F22       -> status=duplicate, excluded from ALL FOUR artifacts
#   - G01..G10  -> 10 high-severity filler (risk > 0, kept by SUMMARY)
#   - Z01..Z05  -> 5 low-severity filler (risk == 0, dropped by the SUMMARY 20-cap)
# Non-duplicate population = 25; SUMMARY keeps the top 20 (every risk>0 record)
# and drops Z01..Z05; F22 never enters the population at all.
#
# Assert PUBLIC behavior only: the contents of the written files and the return
# code, never the internal jq filter, helper names, or exact heading layout.

set -uo pipefail
# shellcheck disable=SC2329  # helper functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
RISK_LIB="$SCRIPT_DIR/lib/risk.sh"
ARTIFACTS_LIB="$SCRIPT_DIR/lib/artifacts.sh"
FIXTURE="$SCRIPT_DIR/tests/fixtures/triage-findings/findings.jsonl"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-triage-artifacts"
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

# assert_rc_zero / assert_rc_eq — the call's return code.
assert_rc_zero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected rc 0, got $rc"; fi
}
assert_rc_eq() {
  local desc="$1" want="$2" rc="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq "$want" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected rc $want, got $rc"; fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected file $path"; fi
}
assert_no_file() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then pass_with "$desc"; else fail_with "$desc" "Unexpected file $path"; fi
}
assert_nonempty() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -s "$path" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected non-empty file $path"; fi
}

# assert_contains — output file holds the literal needle.
assert_contains() {
  local desc="$1" needle="$2" path="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -qF -- "$needle" "$path"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find '$needle' in $path"
  fi
}

# assert_not_contains — needle absent (also passes if the file was not written).
assert_not_contains() {
  local desc="$1" needle="$2" path="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -qF -- "$needle" "$path"; then
    fail_with "$desc" "Did not expect '$needle' in $path"
  else
    pass_with "$desc"
  fi
}

# assert_before — <earlier> appears on an earlier line than <later> (ordering).
assert_before() {
  local desc="$1" earlier="$2" later="$3" path="$4"
  TOTAL=$((TOTAL + 1))
  local la lb
  la="$(grep -nF -- "$earlier" "$path" 2>/dev/null | head -1 | cut -d: -f1)"
  lb="$(grep -nF -- "$later" "$path" 2>/dev/null | head -1 | cut -d: -f1)"
  if [[ -n "$la" && -n "$lb" && "$la" -lt "$lb" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$earlier' (line ${la:-none}) before '$later' (line ${lb:-none})"
  fi
}

# assert_match_count — exactly <expected> DISTINCT matches of the ERE <pattern>.
#   Used to count rendered entries WITHOUT pinning the heading layout.
assert_match_count() {
  local desc="$1" pattern="$2" expected="$3" path="$4"
  TOTAL=$((TOTAL + 1))
  local actual
  actual="$(grep -oE -- "$pattern" "$path" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  if [[ "$actual" -eq "$expected" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $expected distinct matches of /$pattern/, got $actual"
  fi
}

# assert_no_crash — stderr shows no bash-level explosion (set -u / syntax).
assert_no_crash() {
  local desc="$1" errfile="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$errfile" ]] && grep -qiE 'unbound variable|syntax error|command not found' "$errfile"; then
    fail_with "$desc" "stderr indicates a crash: $(head -1 "$errfile")"
  else
    pass_with "$desc"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source the libraries. core.sh + risk.sh first (harmless if the generators
# do not reuse them); artifacts.sh defines all four generators. Assert on the
# FUNCTIONS, not the file. -----------------------------------------------------
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$RISK_LIB" ]] && source "$RISK_LIB"
# shellcheck source=/dev/null
[[ -f "$ARTIFACTS_LIB" ]] && source "$ARTIFACTS_LIB"

# jq is required by the generators; SKIP cleanly off-CI rather than report a
# spurious failure (mirrors the require_jq pattern in test_health_gate.sh).
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH — the triage generators require jq."
  echo ""
  echo "Results: 0 passed, 0 failed, 0 total"
  exit 0
fi

for fn in generate_todo_md generate_summary_md generate_needs_review_md generate_duplicates_md; do
  TOTAL=$((TOTAL + 1))
  if declare -F "$fn" >/dev/null 2>&1; then
    pass_with "$fn is defined after sourcing lib/artifacts.sh"
  else
    fail_with "$fn is defined after sourcing lib/artifacts.sh" "not found in lib/artifacts.sh"
    finish
  fi
done

assert_file_exists "committed fixture findings.jsonl exists" "$FIXTURE"

# ===========================================================================
# Run all four generators against the ONE shared fixture into a temp final/ dir.
# Each generator gets its own stderr capture so we can assert no-crash.
# ===========================================================================
FINAL="$TMPDIR/final"
TODO_OUT="$FINAL/TODO.md"
SUMMARY_OUT="$FINAL/SUMMARY.md"
NR_OUT="$FINAL/NEEDS_REVIEW.md"
DUP_OUT="$FINAL/DUPLICATES.md"

generate_todo_md         "$FIXTURE" "$TODO_OUT"    2>"$TMPDIR/todo.err";    TODO_RC=$?
generate_summary_md      "$FIXTURE" "$SUMMARY_OUT" 2>"$TMPDIR/summary.err"; SUMMARY_RC=$?
generate_needs_review_md "$FIXTURE" "$NR_OUT"      2>"$TMPDIR/nr.err";      NR_RC=$?
generate_duplicates_md   "$FIXTURE" "$DUP_OUT"     2>"$TMPDIR/dup.err";     DUP_RC=$?

assert_rc_zero "generate_todo_md         -> rc 0 on the fixture" "$TODO_RC"
assert_rc_zero "generate_summary_md      -> rc 0 on the fixture" "$SUMMARY_RC"
assert_rc_zero "generate_needs_review_md -> rc 0 on the fixture" "$NR_RC"
assert_rc_zero "generate_duplicates_md   -> rc 0 on the fixture" "$DUP_RC"

assert_file_exists "TODO.md written"         "$TODO_OUT"
assert_file_exists "SUMMARY.md written"      "$SUMMARY_OUT"
assert_file_exists "NEEDS_REVIEW.md written" "$NR_OUT"
assert_file_exists "DUPLICATES.md written"   "$DUP_OUT"

assert_no_crash "generate_todo_md         did not crash" "$TMPDIR/todo.err"
assert_no_crash "generate_summary_md      did not crash" "$TMPDIR/summary.err"
assert_no_crash "generate_needs_review_md did not crash" "$TMPDIR/nr.err"
assert_no_crash "generate_duplicates_md   did not crash" "$TMPDIR/dup.err"

# ===========================================================================
# TODO.md — actionable set: status=new AND not (confidence number < 0.5).
# ===========================================================================
assert_contains     "TODO includes F01 (critical, unscored confidence kept)"  "F01-TODO-CRIT"     "$TODO_OUT"
assert_contains     "TODO includes F02 (high, confidence 0.9)"                 "F02-TODO-HIGHCONF" "$TODO_OUT"
assert_contains     "TODO includes F03 (medium, confidence 0.6)"              "F03-TODO-NULLMD"   "$TODO_OUT"
assert_contains     "TODO includes F13 (the P4 overlap: new + external scanner)" "F13-NR-SCANNER" "$TODO_OUT"
assert_contains     "TODO includes F20 (canonical is status=new, high conf)"   "F20-DUP-CANON"    "$TODO_OUT"
assert_contains     "TODO includes F21 (singleton, actionable)"               "F21-SINGLE"        "$TODO_OUT"
# Exclusions — the partition vs NEEDS_REVIEW / DUPLICATES.
assert_not_contains "TODO excludes F10 (status needs-validation)"             "F10-NR-NEEDSVAL"   "$TODO_OUT"
assert_not_contains "TODO excludes F11 (status likely-false-positive)"        "F11-NR-LFP"        "$TODO_OUT"
assert_not_contains "TODO excludes F12 (status=new but confidence 0.3 < 0.5)" "F12-NR-LOWCONF"    "$TODO_OUT"
assert_not_contains "TODO excludes F22 (status duplicate)"                    "F22-DUP-COPY"      "$TODO_OUT"
# Each entry shows severity / type / primary_location and links markdown_path.
assert_contains "TODO entries show a Severity field"      "- **Severity:**"      "$TODO_OUT"
assert_contains "TODO entries show a Type field"          "- **Type:**"          "$TODO_OUT"
assert_contains "TODO entries show a Location field"      "- **Location:**"      "$TODO_OUT"
assert_contains "TODO shows F02 primary_location"         "src/auth.go:42"       "$TODO_OUT"
assert_contains "TODO links F02 markdown_path"            "](002-highconf.md)"   "$TODO_OUT"
# Defensive rendering: null type/location -> em dash (F01), never the literal "null".
assert_contains     "TODO renders null type as em dash"      "- **Type:** —"     "$TODO_OUT"
assert_contains     "TODO renders null location as em dash"  "- **Location:** —" "$TODO_OUT"
assert_not_contains "TODO never emits a broken empty link"   "]()"               "$TODO_OUT"
assert_not_contains "TODO never leaks the literal 'null'"    "null"              "$TODO_OUT"

# ===========================================================================
# NEEDS_REVIEW.md — every predicate P1..P5 lights up exactly its named reason.
# ===========================================================================
assert_contains "NEEDS_REVIEW includes F10 (P1 needs-validation)"      "F10-NR-NEEDSVAL" "$NR_OUT"
assert_contains "NEEDS_REVIEW includes F11 (P2 likely-false-positive)" "F11-NR-LFP"      "$NR_OUT"
assert_contains "NEEDS_REVIEW includes F12 (P3 low confidence)"        "F12-NR-LOWCONF"  "$NR_OUT"
assert_contains "NEEDS_REVIEW includes F13 (P4 external scanner)"      "F13-NR-SCANNER"  "$NR_OUT"
assert_contains "NEEDS_REVIEW includes F14 (P5 contradictory)"         "F14-NR-CONTRA"   "$NR_OUT"
assert_contains "NEEDS_REVIEW shows the P1 reason"  "needs validation"       "$NR_OUT"
assert_contains "NEEDS_REVIEW shows the P2 reason"  "likely false positive"  "$NR_OUT"
assert_contains "NEEDS_REVIEW shows the P3 reason w/ the value" "low confidence (0.3)" "$NR_OUT"
assert_contains "NEEDS_REVIEW shows the P4 reason"  "needs external scanner" "$NR_OUT"
assert_contains "NEEDS_REVIEW shows the P5 reason"  "contradictory validation" "$NR_OUT"
assert_contains "NEEDS_REVIEW entries carry a named reason field" "- **Needs review:**" "$NR_OUT"
# Clean actionable findings (no predicate) must NOT appear here.
assert_not_contains "NEEDS_REVIEW excludes F01 (clean actionable)" "F01-TODO-CRIT"     "$NR_OUT"
assert_not_contains "NEEDS_REVIEW excludes F02 (clean actionable)" "F02-TODO-HIGHCONF" "$NR_OUT"
assert_not_contains "NEEDS_REVIEW excludes F22 (status duplicate)" "F22-DUP-COPY"      "$NR_OUT"
assert_not_contains "NEEDS_REVIEW never leaks the literal 'null'"  "null"              "$NR_OUT"

# ===========================================================================
# DUPLICATES.md — only the canonical with a non-empty also_reported_by renders;
# singletons and the non-canonical copy are excluded.
# ===========================================================================
assert_contains     "DUPLICATES renders the canonical F20"          "F20-DUP-CANON"      "$DUP_OUT"
assert_contains     "DUPLICATES shows the group identity"           "g1"                 "$DUP_OUT"
assert_contains     "DUPLICATES counts the 2 other reporters"       "2 other lens(es)"   "$DUP_OUT"
assert_contains     "DUPLICATES lists contributor 1 (domain/lens)"  "security/secret-scan"   "$DUP_OUT"
assert_contains     "DUPLICATES lists contributor 2 (domain/lens)"  "reliability/race-detector" "$DUP_OUT"
assert_contains     "DUPLICATES links a contributor markdown_path"  "020-a.md"           "$DUP_OUT"
assert_contains     "DUPLICATES links the canonical markdown_path"  "](020-canon.md)"    "$DUP_OUT"
assert_not_contains "DUPLICATES excludes the singleton F21"         "F21-SINGLE"         "$DUP_OUT"
assert_not_contains "DUPLICATES excludes the non-canonical copy F22" "F22-DUP-COPY"      "$DUP_OUT"
assert_not_contains "DUPLICATES excludes a plain singleton F01"     "F01-TODO-CRIT"      "$DUP_OUT"
assert_not_contains "DUPLICATES never leaks the literal 'null'"     "null"               "$DUP_OUT"
# Exactly one merged group renders (only F20 has also_reported_by).
assert_match_count  "DUPLICATES renders exactly 1 merged group" '^## \[' 1 "$DUP_OUT"

# ===========================================================================
# SUMMARY.md — risk = severity rank x confidence; ordering + the 20-entry cap.
# Top 20 = every risk>0 record; Z01..Z05 (risk 0) are dropped; F22 (duplicate)
# never enters the population.
# ===========================================================================
assert_match_count  "SUMMARY renders EXACTLY 20 entries (top-20 cap)" '^## [0-9]+\. \[' 20 "$SUMMARY_OUT"
assert_contains     "SUMMARY includes the highest-risk F20 (risk 2.85)" "F20-DUP-CANON"    "$SUMMARY_OUT"
assert_contains     "SUMMARY includes F14 (rank 20 — the cap boundary)"  "F14-NR-CONTRA"   "$SUMMARY_OUT"
assert_before       "SUMMARY orders F20 (2.85) before F02 (1.80)" "F20-DUP-CANON" "F02-TODO-HIGHCONF" "$SUMMARY_OUT"
assert_before       "SUMMARY orders F02 (1.80) before F01 (1.50)" "F02-TODO-HIGHCONF" "F01-TODO-CRIT"  "$SUMMARY_OUT"
# The five low-severity (risk 0) records fall past the cap.
assert_not_contains "SUMMARY drops Z01 (risk 0, beyond rank 20)" "Z01-DROP" "$SUMMARY_OUT"
assert_not_contains "SUMMARY drops Z02 (risk 0, beyond rank 20)" "Z02-DROP" "$SUMMARY_OUT"
assert_not_contains "SUMMARY drops Z03 (risk 0, beyond rank 20)" "Z03-DROP" "$SUMMARY_OUT"
assert_not_contains "SUMMARY drops Z04 (risk 0, beyond rank 20)" "Z04-DROP" "$SUMMARY_OUT"
assert_not_contains "SUMMARY drops Z05 (risk 0, beyond rank 20)" "Z05-DROP" "$SUMMARY_OUT"
# Duplicates never consume a SUMMARY slot.
assert_not_contains "SUMMARY excludes F22 (status duplicate)" "F22-DUP-COPY" "$SUMMARY_OUT"
assert_contains "SUMMARY entries show a Severity field" "- **Severity:**" "$SUMMARY_OUT"
assert_contains "SUMMARY entries show a Location field" "- **Location:**" "$SUMMARY_OUT"
assert_not_contains "SUMMARY never leaks the literal 'null'" "null" "$SUMMARY_OUT"

# ===========================================================================
# Empty-registry path — a present-but-empty registry writes a valid non-empty
# file (empty-state note) with rc 0 and NO spurious entries. Use a SEPARATE temp
# file, never the committed fixture.
# ===========================================================================
EMPTY_IN="$TMPDIR/empty.jsonl"
: >"$EMPTY_IN"
EFINAL="$TMPDIR/empty-final"

generate_todo_md         "$EMPTY_IN" "$EFINAL/TODO.md"          2>/dev/null; E_TODO_RC=$?
generate_summary_md      "$EMPTY_IN" "$EFINAL/SUMMARY.md"       2>/dev/null; E_SUMMARY_RC=$?
generate_needs_review_md "$EMPTY_IN" "$EFINAL/NEEDS_REVIEW.md"  2>/dev/null; E_NR_RC=$?
generate_duplicates_md   "$EMPTY_IN" "$EFINAL/DUPLICATES.md"    2>/dev/null; E_DUP_RC=$?

assert_rc_zero "empty registry -> generate_todo_md rc 0"         "$E_TODO_RC"
assert_rc_zero "empty registry -> generate_summary_md rc 0"      "$E_SUMMARY_RC"
assert_rc_zero "empty registry -> generate_needs_review_md rc 0" "$E_NR_RC"
assert_rc_zero "empty registry -> generate_duplicates_md rc 0"   "$E_DUP_RC"

for f in TODO SUMMARY NEEDS_REVIEW DUPLICATES; do
  assert_file_exists "empty registry -> $f.md is written"     "$EFINAL/$f.md"
  assert_nonempty    "empty registry -> $f.md is non-empty"   "$EFINAL/$f.md"
  assert_not_contains "empty registry -> $f.md has no fixture entry" "F20-DUP-CANON" "$EFINAL/$f.md"
  assert_not_contains "empty registry -> $f.md has no fixture entry (F02)" "F02-TODO-HIGHCONF" "$EFINAL/$f.md"
done

# ===========================================================================
# Missing-input path — a missing/unreadable input returns 2 and writes nothing.
# ===========================================================================
MISSING_IN="$TMPDIR/does-not-exist.jsonl"
MFINAL="$TMPDIR/missing-final"

generate_todo_md         "$MISSING_IN" "$MFINAL/TODO.md"         2>/dev/null; M_TODO_RC=$?
generate_summary_md      "$MISSING_IN" "$MFINAL/SUMMARY.md"      2>/dev/null; M_SUMMARY_RC=$?
generate_needs_review_md "$MISSING_IN" "$MFINAL/NEEDS_REVIEW.md" 2>/dev/null; M_NR_RC=$?
generate_duplicates_md   "$MISSING_IN" "$MFINAL/DUPLICATES.md"   2>/dev/null; M_DUP_RC=$?

assert_rc_eq "missing input -> generate_todo_md rc 2"         2 "$M_TODO_RC"
assert_rc_eq "missing input -> generate_summary_md rc 2"      2 "$M_SUMMARY_RC"
assert_rc_eq "missing input -> generate_needs_review_md rc 2" 2 "$M_NR_RC"
assert_rc_eq "missing input -> generate_duplicates_md rc 2"   2 "$M_DUP_RC"
assert_no_file "missing input -> generate_todo_md writes nothing"         "$MFINAL/TODO.md"
assert_no_file "missing input -> generate_summary_md writes nothing"      "$MFINAL/SUMMARY.md"
assert_no_file "missing input -> generate_needs_review_md writes nothing" "$MFINAL/NEEDS_REVIEW.md"
assert_no_file "missing input -> generate_duplicates_md writes nothing"   "$MFINAL/DUPLICATES.md"

finish
