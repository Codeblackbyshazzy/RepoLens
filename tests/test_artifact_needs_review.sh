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

# Tests for issue #326: generate final/NEEDS_REVIEW.md from findings.jsonl
# (the "a human must look at this" list). Pure-function tests only; NO AI models
# are invoked — all input is handwritten JSON-Lines fixtures (CLAUDE.md hard rule).
#
# Contract under test (issue #326 acceptance criteria + the owner's research
# comment, which is the authoritative spec for the open design calls — same
# convention the sibling test_artifact_todo.sh follows):
#
#   generate_needs_review_md <findings_jsonl> <out_file>
#     Reads the finding registry (JSON Lines, schema in
#     docs/finding-registry-schema.md), selects the UNCERTAIN subset, and writes
#     a Markdown file at <out_file>. One entry per finding showing severity,
#     type, primary_location, a link to its markdown_path, AND a short reason it
#     needs review (which predicate matched).
#
#   INCLUSION PREDICATE — NEEDS_REVIEW is the complement of TODO.md's actionable
#   set over NON-DUPLICATE findings, unioned with two validation-derived reasons.
#   A finding is included iff status != "duplicate" AND any of:
#     P1  status == "needs-validation"            (classifier #334 flagged it)
#     P2  status == "likely-false-positive"       (classifier flagged probable FP)
#     P3  confidence is a number BELOW threshold  (explicitly low confidence)
#     P4  validation.suggested_validation names an external scanner
#           (the load-bearing phrase "needs external scanner", prompts/_base/audit.md:50)
#     P5  validation marks a contradiction        (conflicting validation signal)
#
#   WHY P2 is included: the issue body defines NEEDS_REVIEW as "the complement of
#   TODO.md's actionable set for non-duplicate findings". TODO requires
#   status == "new", so a non-duplicate `likely-false-positive` is NOT in TODO and
#   therefore IS in the complement — a human should confirm the FP call. The
#   research recommends including it; both lists together must lose no non-duplicate
#   finding through the cracks. (If the implementer documents EXCLUDING it, this
#   assertion is the deliberate signal to reconcile that choice.)
#
#   WHY the duplicate guard wins over P3: a low-confidence DUPLICATE is the
#   DUPLICATES.md artifact's job, not NEEDS_REVIEW's. status is single-valued, so
#   the top-level status != "duplicate" guard removes it even though P3 would
#   otherwise pull it in.
#
# Design notes that shape these tests (mirroring the discipline of the sibling
# test_artifact_todo.sh test-dev stage):
#   - We test PUBLIC behavior: the contents of the written file and the return
#     code — never the internal jq filter / helper names / exact layout.
#   - The function is expected in lib/artifacts.sh (next to generate_todo_md, per
#     research), with a lib/summary.sh fallback. We source whichever defines
#     generate_needs_review_md and assert on the FUNCTION, not the file.
#   - The P3 THRESHOLD VALUE is the implementer's documented choice (research
#     suggests 0.5, the same constant TODO uses, to keep the two lists an exact
#     complement). So confidence fixtures use values that are unambiguous for any
#     reasonable threshold in [0.33, 0.7]: 0.9 (clearly NOT low), 0.2 (clearly
#     low). The exact boundary (0.49 vs 0.5) is deliberately NOT pinned here — it
#     is the coverage stage's job once the code chooses, exactly as the sibling
#     test left it.
#   - The empty-PRESENT-file return code is NOT pinned (research sanctions rc 0 +
#     empty-state OR rc != 0 + nothing); only "no spurious entries, no crash" is
#     asserted. The MISSING-input rc IS pinned non-zero — issue scope ("does not
#     error the caller" via a clean return, no crash) and research ("return 2,
#     nothing written") agree it is a clean non-zero return.
#   - P4/P5 inspect the opaque `validation` object via the research-recommended,
#     forward-compatible conventions: suggested_validation ~ "external scanner",
#     and a `contradictory: true` marker. These degrade to no-match on today's
#     empty `{}`. The fixtures author validation objects to exercise them.

set -uo pipefail
# shellcheck disable=SC2329  # helper functions are invoked indirectly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
RISK_LIB="$SCRIPT_DIR/lib/risk.sh"
ARTIFACTS_LIB="$SCRIPT_DIR/lib/artifacts.sh"
SUMMARY_LIB="$SCRIPT_DIR/lib/summary.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-artifact-needs-review"
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

# assert_rc_zero / assert_rc_nonzero — the call's return code.
assert_rc_zero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected rc 0, got $rc"; fi
}
assert_rc_nonzero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -ne 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected non-zero rc, got 0"; fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected file $path"; fi
}
assert_nonempty() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -s "$path" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected non-empty file $path"; fi
}

# assert_contains / assert_contains_ci — output file holds the literal needle.
assert_contains() {
  local desc="$1" needle="$2" path="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -qF -- "$needle" "$path"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find '$needle' in $path"
  fi
}
assert_contains_ci() {
  local desc="$1" needle="$2" path="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -qiF -- "$needle" "$path"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find (ci) '$needle' in $path"
  fi
}

# assert_contains_after — the (case-insensitive) needle appears at or AFTER the
#   line that holds <anchor>. Used for per-entry REASON labelling: anchoring on a
#   finding's unique title isolates that entry from the file header, so a reason
#   phrase the generator also prints in its header/predicate description cannot
#   make the assertion pass on its own. With one qualifying finding per fixture,
#   "from the title onward" is exactly that finding's entry. Both anchor and
#   needle are matched literally (awk index / grep -F).
assert_contains_after() {
  local desc="$1" anchor="$2" needle="$3" path="$4"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] \
     && awk -v a="$anchor" 'index($0, a) { f = 1 } f' "$path" | grep -qiF -- "$needle"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$needle' at/after anchor '$anchor' in $path"
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

# assert_no_crash — stderr shows no bash-level explosion (set -u / syntax).
#   Intentional warnings are fine; an unbound-variable / syntax crash is not.
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

# run_gen <jsonl-content> — write the fixture, invoke the generator, capture
#   GEN_IN / GEN_OUT / GEN_ERR (paths) and GEN_RC (return code).
GEN_N=0
run_gen() {
  local content="$1"
  GEN_N=$((GEN_N + 1))
  GEN_IN="$TMPDIR/findings-$GEN_N.jsonl"
  GEN_OUT="$TMPDIR/needs-review-$GEN_N.md"
  GEN_ERR="$TMPDIR/err-$GEN_N.txt"
  printf '%s' "$content" >"$GEN_IN"
  generate_needs_review_md "$GEN_IN" "$GEN_OUT" 2>"$GEN_ERR"
  GEN_RC=$?
}

# run_gen_missing — invoke the generator against an input path that does not
#   exist (the "missing input" edge). Captures GEN_OUT / GEN_ERR / GEN_RC.
run_gen_missing() {
  GEN_N=$((GEN_N + 1))
  GEN_OUT="$TMPDIR/needs-review-$GEN_N.md"
  GEN_ERR="$TMPDIR/err-$GEN_N.txt"
  generate_needs_review_md "$TMPDIR/does-not-exist-$GEN_N.jsonl" "$GEN_OUT" 2>"$GEN_ERR"
  GEN_RC=$?
}

# --- Source the library (core.sh + risk.sh first; the generator MAY reuse the
# shared severity/risk helpers, and sourcing them is harmless if it does not).
# Prefer lib/artifacts.sh (research recommendation, alongside generate_todo_md);
# fall back to lib/summary.sh. Assert on the FUNCTION, not the file. ------------
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$RISK_LIB" ]] && source "$RISK_LIB"
if [[ -f "$ARTIFACTS_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$ARTIFACTS_LIB"
fi
if ! declare -F generate_needs_review_md >/dev/null 2>&1 && [[ -f "$SUMMARY_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$SUMMARY_LIB"
fi

TOTAL=$((TOTAL + 1))
if declare -F generate_needs_review_md >/dev/null 2>&1; then
  pass_with "generate_needs_review_md is defined after sourcing (artifacts.sh or summary.sh)"
else
  fail_with "generate_needs_review_md is defined after sourcing (artifacts.sh or summary.sh)" \
    "not found in lib/artifacts.sh or lib/summary.sh"
  finish
fi

# ===========================================================================
# AC: uncertain findings are included AND each names its review reason. One
# fixture per category, a SINGLE qualifying finding each, so assert_contains_after
# attributes the reason to THAT entry (not the file header). Titles are neutral
# tokens (CASE-*) chosen to share no substring with any reason phrase.
# ===========================================================================

# --- P1: status == "needs-validation" -> included, reason names "needs validation".
read -r -d '' FIX_P1 <<'EOF' || true
{"id":"p1","title":"CASE-NEEDSVAL","severity":"high","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"a.sh:10","confidence":null,"duplicate_group":null,"markdown_path":"001-a.md","validation":{}}
EOF
run_gen "$FIX_P1"
assert_rc_zero          "P1 needs-validation -> success rc" "$GEN_RC"
assert_file_exists      "P1 writes a Markdown file at out_file" "$GEN_OUT"
assert_nonempty         "P1 output is non-empty when a finding needs review" "$GEN_OUT"
assert_contains         "P1 needs-validation finding is INCLUDED" "CASE-NEEDSVAL" "$GEN_OUT"
assert_contains_after   "P1 entry names the review reason (needs validation)" \
  "CASE-NEEDSVAL" "needs validation" "$GEN_OUT"

# --- P2: status == "likely-false-positive" -> included (complement of TODO),
#         reason names "false positive". See header note on the include choice.
read -r -d '' FIX_P2 <<'EOF' || true
{"id":"p2","title":"CASE-FALSEPOS","severity":"high","type":"security","domain":"d","lens":"l","status":"likely-false-positive","primary_location":"b.sh:20","confidence":null,"duplicate_group":null,"markdown_path":"002-b.md","validation":{}}
EOF
run_gen "$FIX_P2"
assert_rc_zero          "P2 likely-false-positive -> success rc" "$GEN_RC"
assert_contains         "P2 likely-false-positive finding is INCLUDED (complement of TODO)" \
  "CASE-FALSEPOS" "$GEN_OUT"
assert_contains_after   "P2 entry names the review reason (false positive)" \
  "CASE-FALSEPOS" "false positive" "$GEN_OUT"

# --- P3: status == "new" but confidence is explicitly low -> included, reason
#         names "low confidence". 0.2 is below any reasonable threshold.
read -r -d '' FIX_P3 <<'EOF' || true
{"id":"p3","title":"CASE-LOWCONF","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"c.sh:30","confidence":0.2,"duplicate_group":null,"markdown_path":"003-c.md","validation":{}}
EOF
run_gen "$FIX_P3"
assert_rc_zero          "P3 low-confidence -> success rc" "$GEN_RC"
assert_contains         "P3 explicitly-low-confidence finding is INCLUDED" "CASE-LOWCONF" "$GEN_OUT"
assert_contains_after   "P3 entry names the review reason (low confidence)" \
  "CASE-LOWCONF" "low confidence" "$GEN_OUT"

# --- P4: validation.suggested_validation names an external scanner -> included,
#         reason names "external scanner". This finding is OTHERWISE actionable
#         (status=new, confidence=0.9): P4 alone pulls it into NEEDS_REVIEW,
#         proving the validation-derived reason is not gated on low confidence.
read -r -d '' FIX_P4 <<'EOF' || true
{"id":"p4","title":"CASE-EXTSCAN","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"d.sh:40","confidence":0.9,"duplicate_group":null,"markdown_path":"004-d.md","validation":{"suggested_validation":"needs external scanner — npm audit (the CVE cannot be confirmed from source alone)"}}
EOF
run_gen "$FIX_P4"
assert_rc_zero          "P4 external-scanner -> success rc" "$GEN_RC"
assert_contains         "P4 external-scanner finding is INCLUDED even though status=new + high confidence" \
  "CASE-EXTSCAN" "$GEN_OUT"
assert_contains_after   "P4 entry names the review reason (external scanner)" \
  "CASE-EXTSCAN" "external scanner" "$GEN_OUT"

# --- P5: validation marks a contradiction -> included, reason names a
#         contradiction. Uses the research-recommended `contradictory: true`
#         marker (forward-compatible; degrades to no-match on `{}`).
read -r -d '' FIX_P5 <<'EOF' || true
{"id":"p5","title":"CASE-CONFLICT","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"e.sh:50","confidence":0.9,"duplicate_group":null,"markdown_path":"005-e.md","validation":{"contradictory":true}}
EOF
run_gen "$FIX_P5"
assert_rc_zero          "P5 contradictory -> success rc" "$GEN_RC"
assert_contains         "P5 contradictory finding is INCLUDED" "CASE-CONFLICT" "$GEN_OUT"
assert_contains_after   "P5 entry names the review reason (contradict...)" \
  "CASE-CONFLICT" "contradict" "$GEN_OUT"

# ===========================================================================
# AC: clearly-confirmed actionable findings are NOT included, and the
# non-duplicate guard wins over a low-confidence DUPLICATE. Mixed fixture, all
# three EXCLUDED:
#   - EXCL-ACTIONABLE : status=new, confidence=0.9, validation={}  -> TODO, not here
#   - EXCL-UNSCORED   : status=new, confidence=null, validation={} -> TODO (neutral)
#   - EXCL-DUPLOW     : status=duplicate, confidence=0.1           -> DUPLICATES, not here
# ===========================================================================
read -r -d '' FIX_EXCLUDE <<'EOF' || true
{"id":"x1","title":"EXCL-ACTIONABLE","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"f.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"006-f.md","validation":{}}
{"id":"x2","title":"EXCL-UNSCORED","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"g.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"007-g.md","validation":{}}
{"id":"x3","title":"EXCL-DUPLOW","severity":"high","type":"security","domain":"d","lens":"l","status":"duplicate","primary_location":"h.sh:1","confidence":0.1,"duplicate_group":"g1","markdown_path":"008-h.md","validation":{}}
EOF
run_gen "$FIX_EXCLUDE"
assert_no_crash     "all-excluded input does not crash the caller" "$GEN_ERR"
assert_not_contains "clearly-actionable (status=new, high confidence) is EXCLUDED" \
  "EXCL-ACTIONABLE" "$GEN_OUT"
assert_not_contains "unscored (status=new, null confidence) is EXCLUDED (goes to TODO)" \
  "EXCL-UNSCORED" "$GEN_OUT"
assert_not_contains "low-confidence DUPLICATE is EXCLUDED (non-duplicate guard wins over P3)" \
  "EXCL-DUPLOW" "$GEN_OUT"

# ===========================================================================
# AC: each entry shows severity, type, primary_location, and links to
# markdown_path. One fully-populated uncertain finding (needs-validation).
# ===========================================================================
read -r -d '' FIX_RENDER <<'EOF' || true
{"id":"r1","title":"RENDER-NR","severity":"critical","type":"reliability","domain":"d","lens":"l","status":"needs-validation","primary_location":"src/app.sh:42","confidence":null,"duplicate_group":null,"markdown_path":"012-render-nr.md","validation":{}}
EOF
run_gen "$FIX_RENDER"
assert_rc_zero     "render fixture -> success rc" "$GEN_RC"
assert_contains    "entry shows the finding title" "RENDER-NR" "$GEN_OUT"
assert_contains_ci "entry shows the severity"      "critical" "$GEN_OUT"
assert_contains    "entry shows the type"          "reliability" "$GEN_OUT"
assert_contains    "entry shows the primary_location" "src/app.sh:42" "$GEN_OUT"
assert_contains    "entry links to markdown_path (Markdown link target)" "](012-render-nr.md)" "$GEN_OUT"

# ===========================================================================
# AC: defensive rendering. null type, empty primary_location, and null
# markdown_path on an uncertain finding must not leak the literal "null" and must
# not emit a broken empty link "[...]()"; the finding itself still appears.
# (P1 finding with null confidence so no numeric value is rendered anywhere.)
# ===========================================================================
read -r -d '' FIX_DEFENSIVE <<'EOF' || true
{"id":"d1","title":"DEFENSIVE-NR","severity":"high","type":null,"domain":"d","lens":"l","status":"needs-validation","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
run_gen "$FIX_DEFENSIVE"
assert_rc_zero      "defensive fixture -> success rc" "$GEN_RC"
assert_contains     "uncertain finding with sparse fields still appears" "DEFENSIVE-NR" "$GEN_OUT"
assert_not_contains "null fields do not leak the literal \"null\" into the Markdown" "null" "$GEN_OUT"
assert_not_contains "null markdown_path does not emit a broken empty link \"[...]()\"" "]()" "$GEN_OUT"

# ===========================================================================
# AC: a finding matching MULTIPLE predicates lists ALL its reasons. status=new,
# confidence=0.2 (P3) AND validation names an external scanner (P4) -> both
# "low confidence" and "external scanner" appear in this entry.
# ===========================================================================
read -r -d '' FIX_MULTI <<'EOF' || true
{"id":"m1","title":"CASE-MULTI","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"m.sh:1","confidence":0.2,"duplicate_group":null,"markdown_path":"050-m.md","validation":{"suggested_validation":"needs external scanner to confirm"}}
EOF
run_gen "$FIX_MULTI"
assert_rc_zero        "multi-reason fixture -> success rc" "$GEN_RC"
assert_contains       "multi-reason finding is INCLUDED" "CASE-MULTI" "$GEN_OUT"
assert_contains_after "multi-reason entry lists the low-confidence reason"  "CASE-MULTI" "low confidence"   "$GEN_OUT"
assert_contains_after "multi-reason entry ALSO lists the external-scanner reason" "CASE-MULTI" "external scanner" "$GEN_OUT"

# ===========================================================================
# AC (research §4): order entries by severity (critical > high > medium > low).
# All qualify (status=needs-validation); input order scrambled so a pass proves
# the generator sorts rather than echoing input order.
# ===========================================================================
read -r -d '' FIX_ORDER <<'EOF' || true
{"id":"o1","title":"ORD-LOW","severity":"low","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"l.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"101-low.md","validation":{}}
{"id":"o2","title":"ORD-CRIT","severity":"critical","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"c.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"102-crit.md","validation":{}}
{"id":"o3","title":"ORD-MED","severity":"medium","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"m.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"103-med.md","validation":{}}
{"id":"o4","title":"ORD-HIGH","severity":"high","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"h.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"104-high.md","validation":{}}
EOF
run_gen "$FIX_ORDER"
assert_before "ordering: critical entry precedes high entry" "ORD-CRIT" "ORD-HIGH" "$GEN_OUT"
assert_before "ordering: high entry precedes medium entry"   "ORD-HIGH" "ORD-MED"  "$GEN_OUT"
assert_before "ordering: medium entry precedes low entry"    "ORD-MED"  "ORD-LOW"  "$GEN_OUT"

# ===========================================================================
# Determinism: same input rendered twice produces byte-identical output (a
# stable sort tiebreak — required so finalize output does not churn run-to-run).
# Reuses the order fixture's input ($GEN_IN from the last run_gen).
# ===========================================================================
DET_OUT_A="$TMPDIR/det-a.md"
DET_OUT_B="$TMPDIR/det-b.md"
generate_needs_review_md "$GEN_IN" "$DET_OUT_A" 2>/dev/null
generate_needs_review_md "$GEN_IN" "$DET_OUT_B" 2>/dev/null
TOTAL=$((TOTAL + 1))
if cmp -s "$DET_OUT_A" "$DET_OUT_B"; then
  pass_with "deterministic: two runs on the same input are byte-identical"
else
  fail_with "deterministic: two runs on the same input are byte-identical" "outputs differ"
fi

# ===========================================================================
# Injection safety: an uncertain finding whose title is packed with shell- and
# Markdown-significant characters must render VERBATIM — no command substitution
# runs, the pipe survives (list layout, not a table), and the structured fields
# still render. (Mirrors the sibling generate_todo_md injection guarantee.)
# ===========================================================================
read -r -d '' FIX_INJECT <<'EOF' || true
{"id":"inj1","title":"INJ-NR |pipe `backtick` $(echo NOTRUN) ]rbracket","severity":"high","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"inj.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"401-inj.md","validation":{}}
EOF
run_gen "$FIX_INJECT"
assert_rc_zero  "special-char title -> success rc" "$GEN_RC"
assert_no_crash "special-char title does not crash the caller" "$GEN_ERR"
assert_contains "special-char title is rendered (entry present)" "INJ-NR" "$GEN_OUT"
assert_contains "command substitution in the title is NOT evaluated (verbatim \$(...) survives)" "\$(echo NOTRUN)" "$GEN_OUT"
assert_contains "a literal pipe in the title survives (list layout, no table breakage)" "|pipe" "$GEN_OUT"
assert_contains "the entry's structured fields still render alongside the messy title" "inj.sh:1" "$GEN_OUT"

# ===========================================================================
# AC: empty input file (0 lines) produces no spurious entries and does not error
# the caller (no set -u explosion). Empty-PRESENT-file rc not pinned (see header).
# ===========================================================================
run_gen ""
assert_no_crash     "empty input file does not crash the caller" "$GEN_ERR"
assert_not_contains "empty input produces no spurious needs-validation reason" "needs validation" "$GEN_OUT"

# ===========================================================================
# AC + research: MISSING / unreadable input -> non-zero rc, no crash, nothing
# meaningful written. Issue scope ("does not error the caller" = clean return)
# and research ("return 2, nothing written") agree the rc is a clean non-zero.
# ===========================================================================
run_gen_missing
assert_rc_nonzero "missing input file -> non-zero rc" "$GEN_RC"
assert_no_crash   "missing input file does not crash the caller (clean return)" "$GEN_ERR"
TOTAL=$((TOTAL + 1))
if [[ ! -e "$GEN_OUT" ]]; then pass_with "missing input writes no output file"
else fail_with "missing input writes no output file" "Unexpected file $GEN_OUT"; fi

# ===========================================================================
# AC: an empty findings-path argument is a bad-arg shape -> non-zero rc, no
# crash, nothing written ("handles empty/missing input without erroring").
# ===========================================================================
BADARG_OUT="$TMPDIR/badarg-out.md"
BADARG_ERR="$TMPDIR/badarg.err"
generate_needs_review_md "" "$BADARG_OUT" 2>"$BADARG_ERR"; BADARG_RC=$?
assert_rc_nonzero "empty findings-path arg -> non-zero rc" "$BADARG_RC"
assert_no_crash   "empty findings-path arg does not crash the caller" "$BADARG_ERR"
TOTAL=$((TOTAL + 1))
if [[ ! -e "$BADARG_OUT" ]]; then pass_with "empty findings-path arg writes no output file"
else fail_with "empty findings-path arg writes no output file" "Unexpected file $BADARG_OUT"; fi

# ===========================================================================
# COVERAGE STAGE — gaps left open for "once the code chooses" + claimed
# behaviors the test-dev fixtures did not exercise. The implementation pinned:
#   - P3 THRESHOLD = 0.5 with strict `< 0.5` (sibling generate_todo_md keeps
#     `>= 0.5`), so 0.5 lands in TODO and 0.49 lands in NEEDS_REVIEW;
#   - empty / all-excluded -> rc 0 + a valid file + "Nothing needs review." note;
#   - a forward-compatible `vobj` guard that degrades to no-match when
#     `validation` is a non-object / null / absent;
#   - case-insensitive matching of the external-scanner escalation phrase;
#   - the top-level duplicate guard winning over EVERY predicate (P4/P5 too).
# ===========================================================================

# --- P3 THRESHOLD BOUNDARY (the deferred 0.49-vs-0.50 call, now that code chose
#     0.5 + strict `<`). 0.50 is the exact complement seam: status=new conf=0.50
#     is actionable (TODO) and must NOT appear here; conf=0.49 is explicitly low
#     and MUST appear with a low-confidence reason. Drift in this constant is the
#     single highest-risk correctness property per the research.
read -r -d '' FIX_BOUNDARY <<'EOF' || true
{"id":"bnd50","title":"BND-AT-050","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"x.sh:1","confidence":0.5,"duplicate_group":null,"markdown_path":"b50.md","validation":{}}
{"id":"bnd49","title":"BND-AT-049","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"y.sh:1","confidence":0.49,"duplicate_group":null,"markdown_path":"b49.md","validation":{}}
EOF
run_gen "$FIX_BOUNDARY"
assert_rc_zero        "boundary fixture -> success rc" "$GEN_RC"
assert_not_contains   "confidence==0.5 (status new) is EXCLUDED — it is actionable (TODO seam)" \
  "BND-AT-050" "$GEN_OUT"
assert_contains       "confidence==0.49 (status new) is INCLUDED — explicitly below 0.5" \
  "BND-AT-049" "$GEN_OUT"
assert_contains_after "boundary 0.49 entry names the low-confidence reason" \
  "BND-AT-049" "low confidence" "$GEN_OUT"

# --- EMPTY / ALL-EXCLUDED CONTRACT (the deferred empty-PRESENT-file rc, now that
#     code chose rc 0 + a written file + an empty-state note). Pins both the
#     0-line input and the present-but-all-excluded input to that contract.
run_gen ""
assert_rc_zero     "empty present file -> rc 0 (implementation's chosen contract)" "$GEN_RC"
assert_file_exists "empty present file still writes a valid Markdown file" "$GEN_OUT"
assert_contains_ci "empty present file shows the empty-state note" "nothing needs review" "$GEN_OUT"

run_gen "$FIX_EXCLUDE"
assert_rc_zero     "all-excluded input -> rc 0" "$GEN_RC"
assert_file_exists "all-excluded input still writes a valid file" "$GEN_OUT"
assert_contains_ci "all-excluded input shows the empty-state note" "nothing needs review" "$GEN_OUT"

# --- DEFENSIVE `vobj` GUARD: a non-object / null / absent `validation` must
#     degrade to no-match (never crash, never spuriously satisfy P4/P5 even when
#     the raw string CONTAINS the escalation phrase), while a well-formed sibling
#     in the SAME batch still renders. STR-VAL's string literally contains
#     "needs external scanner": if the guard were missing it would either crash
#     jq (indexing a string) or wrongly match — its EXCLUSION proves the guard.
read -r -d '' FIX_VOBJ <<'EOF' || true
{"id":"v1","title":"VOBJ-STR","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"s.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"vs.md","validation":"needs external scanner"}
{"id":"v2","title":"VOBJ-NULL","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"n.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"vn.md","validation":null}
{"id":"v3","title":"VOBJ-ABSENT","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"a.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"va.md"}
{"id":"v4","title":"VOBJ-GOOD","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"g.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"vg.md","validation":{"suggested_validation":"needs external scanner"}}
EOF
run_gen "$FIX_VOBJ"
assert_rc_zero      "non-object validation fixture -> success rc" "$GEN_RC"
assert_no_crash     "non-object/null/absent validation does not crash the caller" "$GEN_ERR"
assert_not_contains "string validation containing the phrase does NOT spuriously match P4" \
  "VOBJ-STR" "$GEN_OUT"
assert_not_contains "null validation degrades to no-match (excluded)" "VOBJ-NULL" "$GEN_OUT"
assert_not_contains "absent validation key degrades to no-match (excluded)" "VOBJ-ABSENT" "$GEN_OUT"
assert_contains     "a well-formed validation sibling in the same batch still renders" \
  "VOBJ-GOOD" "$GEN_OUT"
assert_contains_after "the well-formed sibling names the external-scanner reason" \
  "VOBJ-GOOD" "external scanner" "$GEN_OUT"

# --- CASE-INSENSITIVE external-scanner match: the escalation phrase in mixed
#     case ("Needs EXTERNAL Scanner") must still match P4 (the code lowercases
#     before testing). The existing P4 fixture uses lowercase only, so this is
#     the assertion that genuinely exercises ascii_downcase.
read -r -d '' FIX_CI_EXT <<'EOF' || true
{"id":"ci1","title":"CI-EXTSCAN","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"ci.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"ci.md","validation":{"suggested_validation":"Needs EXTERNAL Scanner before acting"}}
EOF
run_gen "$FIX_CI_EXT"
assert_rc_zero        "mixed-case external-scanner fixture -> success rc" "$GEN_RC"
assert_contains       "mixed-case 'Needs EXTERNAL Scanner' matches P4 (case-insensitive)" \
  "CI-EXTSCAN" "$GEN_OUT"
assert_contains_after "mixed-case external-scanner entry names the external-scanner reason" \
  "CI-EXTSCAN" "external scanner" "$GEN_OUT"

# --- DUPLICATE GUARD WINS OVER P4 AND P5 (not just P3). The existing EXCL-DUPLOW
#     proves the top-level `status != "duplicate"` guard beats P3 (low confidence).
#     These two prove it also beats the validation-derived predicates: a duplicate
#     that names an external scanner OR is marked contradictory is still EXCLUDED
#     (it belongs to the future DUPLICATES artifact).
read -r -d '' FIX_DUP_VAL <<'EOF' || true
{"id":"dv1","title":"DUP-EXTSCAN","severity":"high","type":"security","domain":"d","lens":"l","status":"duplicate","primary_location":"de.sh:1","confidence":0.9,"duplicate_group":"g1","markdown_path":"de.md","validation":{"suggested_validation":"needs external scanner"}}
{"id":"dv2","title":"DUP-CONTRA","severity":"high","type":"security","domain":"d","lens":"l","status":"duplicate","primary_location":"dc.sh:1","confidence":0.9,"duplicate_group":"g2","markdown_path":"dc.md","validation":{"contradictory":true}}
EOF
run_gen "$FIX_DUP_VAL"
assert_rc_zero      "duplicate-with-validation fixture -> success rc" "$GEN_RC"
assert_not_contains "duplicate with external-scanner validation is EXCLUDED (guard wins over P4)" \
  "DUP-EXTSCAN" "$GEN_OUT"
assert_not_contains "duplicate marked contradictory is EXCLUDED (guard wins over P5)" \
  "DUP-CONTRA" "$GEN_OUT"

# ===========================================================================
# EXACT-COMPLEMENT INVARIANT (research's "single most important correctness
# property"): over NON-DUPLICATE findings, TODO and NEEDS_REVIEW must partition
# the set — every finding lands in exactly one list, with no gap and no overlap.
# Run BOTH real generators over the same fixture and assert each finding appears
# in its expected list and is absent from the other. Guarded on generate_todo_md
# being available (it is the sibling in lib/artifacts.sh); skipped, not failed,
# if only NEEDS_REVIEW was sourced.
# ===========================================================================
if declare -F generate_todo_md >/dev/null 2>&1; then
  read -r -d '' FIX_PARTITION <<'EOF' || true
{"id":"k1","title":"PART-TODO-HI","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"k1.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"k1.md","validation":{}}
{"id":"k2","title":"PART-TODO-50","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"k2.sh:1","confidence":0.5,"duplicate_group":null,"markdown_path":"k2.md","validation":{}}
{"id":"k3","title":"PART-TODO-NULL","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"k3.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"k3.md","validation":{}}
{"id":"k4","title":"PART-NR-49","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"k4.sh:1","confidence":0.49,"duplicate_group":null,"markdown_path":"k4.md","validation":{}}
{"id":"k5","title":"PART-NR-NEEDSVAL","severity":"high","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"k5.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"k5.md","validation":{}}
{"id":"k6","title":"PART-NR-FP","severity":"high","type":"security","domain":"d","lens":"l","status":"likely-false-positive","primary_location":"k6.sh:1","confidence":null,"duplicate_group":null,"markdown_path":"k6.md","validation":{}}
EOF
  PART_IN="$TMPDIR/partition.jsonl"
  PART_NR="$TMPDIR/partition-nr.md"
  PART_TODO="$TMPDIR/partition-todo.md"
  printf '%s' "$FIX_PARTITION" >"$PART_IN"
  generate_needs_review_md "$PART_IN" "$PART_NR" 2>/dev/null
  generate_todo_md "$PART_IN" "$PART_TODO" 2>/dev/null

  # TODO-bound findings: present in TODO, absent from NEEDS_REVIEW.
  assert_contains     "partition: new+high-conf is in TODO" "PART-TODO-HI" "$PART_TODO"
  assert_not_contains "partition: new+high-conf is NOT in NEEDS_REVIEW" "PART-TODO-HI" "$PART_NR"
  assert_contains     "partition: new+conf-0.50 is in TODO (seam, inclusive)" "PART-TODO-50" "$PART_TODO"
  assert_not_contains "partition: new+conf-0.50 is NOT in NEEDS_REVIEW" "PART-TODO-50" "$PART_NR"
  assert_contains     "partition: new+unscored is in TODO (neutral)" "PART-TODO-NULL" "$PART_TODO"
  assert_not_contains "partition: new+unscored is NOT in NEEDS_REVIEW" "PART-TODO-NULL" "$PART_NR"

  # NEEDS_REVIEW-bound findings: present in NEEDS_REVIEW, absent from TODO.
  assert_contains     "partition: new+conf-0.49 is in NEEDS_REVIEW (explicitly low)" "PART-NR-49" "$PART_NR"
  assert_not_contains "partition: new+conf-0.49 is NOT in TODO" "PART-NR-49" "$PART_TODO"
  assert_contains     "partition: needs-validation is in NEEDS_REVIEW" "PART-NR-NEEDSVAL" "$PART_NR"
  assert_not_contains "partition: needs-validation is NOT in TODO" "PART-NR-NEEDSVAL" "$PART_TODO"
  assert_contains     "partition: likely-false-positive is in NEEDS_REVIEW" "PART-NR-FP" "$PART_NR"
  assert_not_contains "partition: likely-false-positive is NOT in TODO" "PART-NR-FP" "$PART_TODO"
else
  echo "  SKIP: generate_todo_md not available — complement-partition cross-check skipped"
fi

finish
