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

# Tests for issue #336: generate final/SUMMARY.md from findings.jsonl — the
# executive "Top 20 findings by risk" view. Pure-function tests only; NO AI
# models are invoked — all input is handwritten JSON-Lines fixtures.
#
# Contract under test (issue #336 AC + the owner's research comment, which is
# the authoritative spec for the open design calls — same precedent as the three
# sibling artifact tests):
#
#   generate_summary_md <findings_jsonl> <out_file>
#     Reads the finding registry (JSON Lines, schema in
#     docs/finding-registry-schema.md), ranks every eligible record by
#     RISK = severity_rank x confidence (descending), takes the TOP 20, and
#     writes a Markdown file at <out_file> with one ranked entry per finding
#     showing severity, type, primary_location and a link to markdown_path.
#
#   RISK (AC #1) — risk = severity rank x confidence, mirroring
#     lib/risk.sh::finding_risk_score / lib/core.sh::severity_rank:
#       severity rank: critical=3, high=2, medium=1, low=0 (unknown sorts last)
#       confidence:    numeric value if present, else 0.5 neutral default
#     Ordering is most-risky-first (AC #2). The cap is 20 (AC #1/#3).
#
#   POPULATION (research §3.2 — the recommended/owner design): rank EVERY record
#     EXCEPT status == "duplicate" (a non-canonical copy would double-count its
#     canonical). Unlike TODO.md there is NO status=="new" gate — SUMMARY is the
#     executive risk view, so a high-risk needs-validation finding still appears;
#     the risk formula de-weights low-confidence items naturally. This is the
#     authoritative design call and is what every sibling does for "duplicate".
#
#   RENDERING is defensive (mirrors the three siblings): null/empty type or
#     primary_location renders as an em dash, never the literal "null"; a
#     null/empty markdown_path emits NO link (never a broken "[...]()"). Fields
#     are emitted verbatim by jq, so a title containing backticks / $() / pipes
#     is data, never shell-evaluated.
#
#   EMPTY / MISSING INPUT (AC #3): a missing/unreadable input path or a bad
#     argument returns 2 and writes nothing (no crash) — the documented sibling
#     contract (research §3.1, "re-use verbatim"). A present-but-empty or
#     all-excluded registry writes a valid (non-empty) file and returns 0.
#
# Design notes that shape these tests:
#   - We test PUBLIC behavior: the contents of the written file and the return
#     code, never the internal jq filter / helper names / exact layout.
#   - The function may live in lib/artifacts.sh (research recommendation) or
#     alongside lib/summary.sh (AC-literal alternative). We source whichever
#     defines generate_summary_md — assert on the FUNCTION, not the file.
#   - Confidence fixtures use values that are unambiguous (0.99..0.75, plus a
#     rank x conf cross-check), so a pass proves risk-multiplication ordering,
#     not merely severity ordering.
#   - The exact empty-state NOTE text and the exact heading layout are the
#     implementer's choice and are NOT pinned — only "valid non-empty file,
#     rc 0, no spurious entries" is asserted for the empty case.

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

TMP_PARENT="$SCRIPT_DIR/logs/test-artifact-summary"
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

# assert_rc_zero / assert_rc_nonzero / assert_rc_eq — the call's return code.
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
assert_contains_ci() {
  local desc="$1" needle="$2" path="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -qiF -- "$needle" "$path"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find (ci) '$needle' in $path"
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
#   Used to count rendered entries WITHOUT pinning the heading layout: each
#   fixture gives findings unique titles (e.g. RANK-07) that appear nowhere else.
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

# run_gen <jsonl-content> — write the fixture, invoke the generator, capture
#   GEN_IN / GEN_OUT / GEN_ERR (paths) and GEN_RC (return code).
GEN_N=0
run_gen() {
  local content="$1"
  GEN_N=$((GEN_N + 1))
  GEN_IN="$TMPDIR/findings-$GEN_N.jsonl"
  GEN_OUT="$TMPDIR/summary-$GEN_N.md"
  GEN_ERR="$TMPDIR/err-$GEN_N.txt"
  printf '%s' "$content" >"$GEN_IN"
  generate_summary_md "$GEN_IN" "$GEN_OUT" 2>"$GEN_ERR"
  GEN_RC=$?
}

# run_gen_missing — invoke against an input path that does not exist.
run_gen_missing() {
  GEN_N=$((GEN_N + 1))
  GEN_OUT="$TMPDIR/summary-$GEN_N.md"
  GEN_ERR="$TMPDIR/err-$GEN_N.txt"
  generate_summary_md "$TMPDIR/does-not-exist-$GEN_N.jsonl" "$GEN_OUT" 2>"$GEN_ERR"
  GEN_RC=$?
}

# --- Source the library (core.sh + risk.sh first; the generator MAY reuse the
# shared severity/risk helpers, and sourcing them is harmless if it does not).
# Prefer lib/artifacts.sh (research recommendation); fall back to lib/summary.sh
# (AC-literal). Assert on the FUNCTION, not the file. ----------------------------
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$RISK_LIB" ]] && source "$RISK_LIB"
if [[ -f "$ARTIFACTS_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$ARTIFACTS_LIB"
fi
if ! declare -F generate_summary_md >/dev/null 2>&1 && [[ -f "$SUMMARY_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$SUMMARY_LIB"
fi

TOTAL=$((TOTAL + 1))
if declare -F generate_summary_md >/dev/null 2>&1; then
  pass_with "generate_summary_md is defined after sourcing (artifacts.sh or summary.sh)"
else
  fail_with "generate_summary_md is defined after sourcing (artifacts.sh or summary.sh)" \
    "not found in lib/artifacts.sh or lib/summary.sh"
  finish
fi

# ===========================================================================
# AC #1/#3: the TOP-20 cap. Feed 25 eligible findings whose risk is strictly
# monotonic (all critical, confidence 0.99 down to 0.75 in 0.01 steps), so
# RANK-01 is the highest-risk and RANK-25 the lowest. The output must contain
# EXACTLY 20 entries: RANK-01..RANK-20 present, RANK-21..RANK-25 dropped by the
# cap. Input is built in a scrambled-free loop; ordering is proven separately.
# ===========================================================================
CAP_FIX=""
for n in $(seq 1 25); do
  id="$(printf 'r%02d' "$n")"
  title="$(printf 'RANK-%02d' "$n")"
  conf="$(printf '0.%02d' "$((100 - n))")"   # n=1 -> 0.99 ... n=25 -> 0.75
  loc="$(printf 'f%02d.sh:1' "$n")"
  mdp="$(printf 'f%02d.md' "$n")"
  CAP_FIX+="$(printf '{"id":"%s","title":"%s","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"%s","confidence":%s,"duplicate_group":null,"markdown_path":"%s","validation":{}}' \
    "$id" "$title" "$loc" "$conf" "$mdp")"
  CAP_FIX+=$'\n'
done
run_gen "$CAP_FIX"
assert_rc_zero     "25-finding fixture -> success rc" "$GEN_RC"
assert_file_exists "writes a SUMMARY.md file at out_file" "$GEN_OUT"
assert_match_count "exactly 20 entries are rendered (top-20 cap)" 'RANK-[0-9][0-9]' 20 "$GEN_OUT"
assert_contains    "highest-risk finding (RANK-01) is present" "RANK-01" "$GEN_OUT"
assert_contains    "20th-ranked finding (RANK-20) is present" "RANK-20" "$GEN_OUT"
assert_not_contains "21st-ranked finding (RANK-21) is dropped by the cap" "RANK-21" "$GEN_OUT"
assert_not_contains "lowest-risk finding (RANK-25) is dropped by the cap" "RANK-25" "$GEN_OUT"
assert_before      "ordering: RANK-01 precedes RANK-02 (most-risky first)" "RANK-01" "RANK-02" "$GEN_OUT"
assert_before      "ordering: RANK-01 precedes RANK-20 (descending risk)" "RANK-01" "RANK-20" "$GEN_OUT"

# ===========================================================================
# AC #1/#2: risk is severity rank x confidence, NOT severity alone. A
# high-confidence HIGH outranks a half-confidence CRITICAL:
#   high     @ 1.0 -> 2 x 1.0 = 2.0   (highest)
#   critical @ 0.5 -> 3 x 0.5 = 1.5
#   medium   @ 1.0 -> 1 x 1.0 = 1.0   (lowest)
# A pure-severity sort would rank the critical first and FAIL this test.
# ===========================================================================
read -r -d '' FIX_RISK <<'EOF' || true
{"id":"k1","title":"RISK-CRIT-HALF","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"c.sh:1","confidence":0.5,"duplicate_group":null,"markdown_path":"c.md","validation":{}}
{"id":"k2","title":"RISK-HIGH-CERTAIN","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"h.sh:1","confidence":1.0,"duplicate_group":null,"markdown_path":"h.md","validation":{}}
{"id":"k3","title":"RISK-MED-CERTAIN","severity":"medium","type":"security","domain":"d","lens":"l","status":"new","primary_location":"m.sh:1","confidence":1.0,"duplicate_group":null,"markdown_path":"m.md","validation":{}}
EOF
run_gen "$FIX_RISK"
assert_rc_zero "risk-ordering fixture -> success rc" "$GEN_RC"
assert_before "risk = rank x conf: high@1.0 (2.0) precedes critical@0.5 (1.5)" "RISK-HIGH-CERTAIN" "RISK-CRIT-HALF" "$GEN_OUT"
assert_before "risk = rank x conf: critical@0.5 (1.5) precedes medium@1.0 (1.0)" "RISK-CRIT-HALF" "RISK-MED-CERTAIN" "$GEN_OUT"

# ===========================================================================
# EQUAL-RISK SEVERITY TIEBREAK (implementation's 2nd sort key): when two
# findings have IDENTICAL risk but different severity, the higher severity must
# win ("severity wins on a tie" — implementation comment / research §3.3). The
# risk-ordering block above uses only DISTINCT risks, so this tiebreak key is
# never exercised there. Here every confidence is an EXACT binary fraction so
# the equal-risk products are bit-identical (no float-equality flakiness):
#   critical @ 0.5  -> 3 x 0.5  = 1.5  ┐ equal risk 1.5; CRITICAL must precede HIGH
#   high     @ 0.75 -> 2 x 0.75 = 1.5  ┘
#   high     @ 0.5  -> 2 x 0.5  = 1.0  ┐ equal risk 1.0; HIGH must precede MEDIUM
#   medium   @ 1.0  -> 1 x 1.0  = 1.0  ┘
# Input is scrambled so a pass proves the tiebreak sort, not echo order.
# ===========================================================================
read -r -d '' FIX_TIE_SEV <<'EOF' || true
{"id":"t3","title":"TIE-HIGH-B","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"hb.sh:1","confidence":0.5,"duplicate_group":null,"markdown_path":"hb.md","validation":{}}
{"id":"t1","title":"TIE-CRIT","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"c.sh:1","confidence":0.5,"duplicate_group":null,"markdown_path":"c.md","validation":{}}
{"id":"t4","title":"TIE-MED","severity":"medium","type":"security","domain":"d","lens":"l","status":"new","primary_location":"m.sh:1","confidence":1.0,"duplicate_group":null,"markdown_path":"m.md","validation":{}}
{"id":"t2","title":"TIE-HIGH-A","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"ha.sh:1","confidence":0.75,"duplicate_group":null,"markdown_path":"ha.md","validation":{}}
EOF
run_gen "$FIX_TIE_SEV"
assert_rc_zero "severity-tiebreak fixture -> success rc" "$GEN_RC"
assert_before "equal risk 1.5: critical@0.5 precedes high@0.75 (severity wins the tie)" "TIE-CRIT" "TIE-HIGH-A" "$GEN_OUT"
assert_before "equal risk 1.0: high@0.5 precedes medium@1.0 (severity wins the tie)" "TIE-HIGH-B" "TIE-MED" "$GEN_OUT"
assert_before "higher-risk group (1.5) precedes lower-risk group (1.0) across ties" "TIE-HIGH-A" "TIE-HIGH-B" "$GEN_OUT"

# ===========================================================================
# AC #2: each entry shows severity, type, primary_location, and links to
# markdown_path. One fully-populated finding.
# ===========================================================================
read -r -d '' FIX_RENDER <<'EOF' || true
{"id":"rf1","title":"RENDER-FULL","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"src/app.sh:42","confidence":0.9,"duplicate_group":null,"markdown_path":"012-render-full.md","validation":{}}
EOF
run_gen "$FIX_RENDER"
assert_rc_zero     "render fixture -> success rc" "$GEN_RC"
assert_contains    "entry shows the finding title" "RENDER-FULL" "$GEN_OUT"
assert_contains_ci "entry shows the severity" "critical" "$GEN_OUT"
assert_contains    "entry shows the type" "security" "$GEN_OUT"
assert_contains    "entry shows the primary_location" "src/app.sh:42" "$GEN_OUT"
assert_contains    "entry links to markdown_path (Markdown link target)" "](012-render-full.md)" "$GEN_OUT"

# ===========================================================================
# AC #3: a run with FEWER than 20 findings emits EXACTLY that many entries.
# ===========================================================================
read -r -d '' FIX_SMALL <<'EOF' || true
{"id":"s1","title":"SMALL-1","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"a.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"a.md","validation":{}}
{"id":"s2","title":"SMALL-2","severity":"medium","type":"security","domain":"d","lens":"l","status":"new","primary_location":"b.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"b.md","validation":{}}
{"id":"s3","title":"SMALL-3","severity":"low","type":"security","domain":"d","lens":"l","status":"new","primary_location":"c.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"c.md","validation":{}}
EOF
run_gen "$FIX_SMALL"
assert_rc_zero     "3-finding fixture -> success rc" "$GEN_RC"
assert_match_count "fewer than 20 findings emit exactly that many entries (3)" 'SMALL-[0-9]' 3 "$GEN_OUT"

# ===========================================================================
# POPULATION (research §3.2 — authoritative design call): rank everything
# EXCEPT status == "duplicate". A non-canonical duplicate must NOT appear
# (it would double-count its canonical). Unlike TODO.md there is NO
# status=="new" gate, so a high-risk needs-validation finding STILL appears.
#   - POP-DUP        : status=duplicate          -> EXCLUDED
#   - POP-NEEDSVAL   : status=needs-validation    -> INCLUDED (no status gate)
#   - POP-NEW        : status=new                 -> INCLUDED
# ===========================================================================
read -r -d '' FIX_POP <<'EOF' || true
{"id":"p1","title":"POP-DUP","severity":"critical","type":"security","domain":"d","lens":"l","status":"duplicate","primary_location":"d.sh:1","confidence":0.9,"duplicate_group":"g1","markdown_path":"d.md","validation":{}}
{"id":"p2","title":"POP-NEEDSVAL","severity":"high","type":"security","domain":"d","lens":"l","status":"needs-validation","primary_location":"n.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"n.md","validation":{}}
{"id":"p3","title":"POP-NEW","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"w.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"w.md","validation":{}}
EOF
run_gen "$FIX_POP"
assert_rc_zero      "population fixture -> success rc" "$GEN_RC"
assert_not_contains "status=duplicate is EXCLUDED (no double-counting the canonical)" "POP-DUP" "$GEN_OUT"
assert_contains     "status=needs-validation is INCLUDED (SUMMARY has no status=new gate)" "POP-NEEDSVAL" "$GEN_OUT"
assert_contains     "status=new is INCLUDED" "POP-NEW" "$GEN_OUT"

# ===========================================================================
# AC #2 (defensive rendering): null type, empty primary_location, and null
# markdown_path must not leak the literal "null" and must not emit a broken
# empty link "[...]()"; the finding itself still appears.
# ===========================================================================
read -r -d '' FIX_DEFENSIVE <<'EOF' || true
{"id":"df1","title":"DEFENSIVE-ENTRY","severity":"high","type":null,"domain":"d","lens":"l","status":"new","primary_location":"","confidence":0.9,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
run_gen "$FIX_DEFENSIVE"
assert_rc_zero      "defensive fixture -> success rc" "$GEN_RC"
assert_contains     "finding with sparse fields still appears" "DEFENSIVE-ENTRY" "$GEN_OUT"
assert_not_contains "null fields do not leak the literal \"null\" into the Markdown" "null" "$GEN_OUT"
assert_not_contains "null markdown_path does not emit a broken empty link \"[...]()\"" "]()" "$GEN_OUT"

# ===========================================================================
# Injection-safety (security lens; documented first-class risk): a title packed
# with shell- and Markdown-significant characters is DATA. No command
# substitution runs (verbatim "$(...)" survives), the pipe survives, the entry
# renders, and the caller does not crash.
# ===========================================================================
read -r -d '' FIX_INJECT <<'EOF' || true
{"id":"ij1","title":"INJ-SUMMARY |pipe `backtick` $(echo NOTRUN) ]rbracket","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"inj.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"inj.md","validation":{}}
EOF
run_gen "$FIX_INJECT"
assert_rc_zero  "special-char title -> success rc" "$GEN_RC"
assert_no_crash "special-char title does not crash the caller" "$GEN_ERR"
assert_contains "special-char title is rendered (entry present)" "INJ-SUMMARY" "$GEN_OUT"
assert_contains "command substitution in the title is NOT evaluated (verbatim \$(...) survives)" "\$(echo NOTRUN)" "$GEN_OUT"
assert_contains "a literal pipe in the title survives (list layout, no table breakage)" "|pipe" "$GEN_OUT"
assert_contains "the entry's structured fields still render alongside the messy title" "inj.sh:1" "$GEN_OUT"

# ===========================================================================
# Determinism: same input rendered twice produces byte-identical output (a
# stable sort tiebreak — required so finalize output does not churn run-to-run).
# Reuses the 3-finding fixture's input (GEN_IN still points at FIX_SMALL? no —
# rebuild a dedicated input to keep this independent of test ordering).
# ===========================================================================
read -r -d '' FIX_DET <<'EOF' || true
{"id":"e2","title":"DET-B","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"b.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"b.md","validation":{}}
{"id":"e1","title":"DET-A","severity":"high","type":"security","domain":"d","lens":"l","status":"new","primary_location":"a.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"a.md","validation":{}}
{"id":"e3","title":"DET-C","severity":"critical","type":"security","domain":"d","lens":"l","status":"new","primary_location":"c.sh:1","confidence":0.5,"duplicate_group":null,"markdown_path":"c.md","validation":{}}
EOF
DET_IN="$TMPDIR/det-in.jsonl"
DET_OUT_A="$TMPDIR/det-a.md"
DET_OUT_B="$TMPDIR/det-b.md"
printf '%s' "$FIX_DET" >"$DET_IN"
generate_summary_md "$DET_IN" "$DET_OUT_A" 2>/dev/null
generate_summary_md "$DET_IN" "$DET_OUT_B" 2>/dev/null
TOTAL=$((TOTAL + 1))
if cmp -s "$DET_OUT_A" "$DET_OUT_B"; then
  pass_with "deterministic: two runs on the same input are byte-identical"
else
  fail_with "deterministic: two runs on the same input are byte-identical" "outputs differ"
fi

# id-ASCENDING tiebreak DIRECTION (implementation's final sort key, "(.id // \"\")").
# cmp -s above proves the tiebreak is STABLE, but not which way it points. The
# fixture lists e2 (DET-B) BEFORE e1 (DET-A) in the input, and both are equal
# risk (high@0.9 = 1.8) with the same severity and confidence — so ONLY the
# id-ascending final key can decide their order. DET-A (id e1) must precede
# DET-B (id e2), i.e. the output order is the id order, NOT the input order.
assert_before "id-ascending tiebreak: equal-risk DET-A (id e1) precedes DET-B (id e2) despite input order" "DET-A" "DET-B" "$DET_OUT_A"
# Sanity: the lower-risk critical@0.5 (1.5) sorts after both 1.8 highs.
assert_before "id tiebreak fixture: equal-risk highs (1.8) precede the lower-risk critical@0.5 (1.5)" "DET-B" "DET-C" "$DET_OUT_A"

# ===========================================================================
# AC #3 (empty input): a present-but-empty (0-line) registry does not error the
# caller — it writes a valid, non-empty file (header / empty-state note) and
# returns 0. The exact note text and layout are NOT pinned (implementer choice).
# ===========================================================================
run_gen ""
assert_rc_zero     "empty input file returns 0 (does not error the caller)" "$GEN_RC"
assert_no_crash    "empty input file does not crash the caller" "$GEN_ERR"
assert_file_exists "empty input still writes a SUMMARY.md artifact" "$GEN_OUT"
assert_nonempty    "empty-input SUMMARY.md is a valid non-empty file" "$GEN_OUT"

# ===========================================================================
# All-excluded input (records exist but every one is status=duplicate) -> the
# same empty-state contract: rc 0, valid file, the duplicate is NOT rendered.
# ===========================================================================
read -r -d '' FIX_ALLEXCL <<'EOF' || true
{"id":"ax1","title":"AX-DUP-ONLY","severity":"critical","type":"security","domain":"d","lens":"l","status":"duplicate","primary_location":"a.sh:1","confidence":0.9,"duplicate_group":"g","markdown_path":"a.md","validation":{}}
EOF
run_gen "$FIX_ALLEXCL"
assert_rc_zero      "all-excluded registry returns 0 (well-formed empty-state, not an error)" "$GEN_RC"
assert_file_exists  "all-excluded registry still writes a SUMMARY.md artifact" "$GEN_OUT"
assert_not_contains "all-excluded: the duplicate finding is not rendered" "AX-DUP-ONLY" "$GEN_OUT"

# ===========================================================================
# AC #3 (missing / bad input): a missing/unreadable input path or an empty
# argument returns the documented rc 2, writes nothing, and does not crash.
# (Sibling contract, research §3.1 "re-use verbatim".)
# ===========================================================================
run_gen_missing
assert_rc_eq    "missing input file returns the documented rc 2" 2 "$GEN_RC"
assert_no_crash "missing input file does not crash the caller (clean return)" "$GEN_ERR"
assert_no_file  "missing input writes no output file" "$GEN_OUT"

# Empty findings-path argument -> rc 2, no crash, nothing written.
BADARG_OUT="$TMPDIR/badarg-out.md"
BADARG_ERR="$TMPDIR/badarg.err"
generate_summary_md "" "$BADARG_OUT" 2>"$BADARG_ERR"; BADARG_RC=$?
assert_rc_eq    "empty findings-path arg returns rc 2" 2 "$BADARG_RC"
assert_no_crash "empty findings-path arg does not crash the caller" "$BADARG_ERR"
assert_no_file  "empty findings-path arg writes no output file" "$BADARG_OUT"

# Empty out-file argument (valid input present) -> rc 2, no crash.
BADARG2_IN="$TMPDIR/badarg2-in.jsonl"
BADARG2_ERR="$TMPDIR/badarg2.err"
printf '%s' '{"id":"q1","title":"Q","severity":"high","status":"new"}' >"$BADARG2_IN"
generate_summary_md "$BADARG2_IN" "" 2>"$BADARG2_ERR"; BADARG2_RC=$?
assert_rc_eq    "empty out-file arg returns rc 2" 2 "$BADARG2_RC"
assert_no_crash "empty out-file arg does not crash the caller" "$BADARG2_ERR"

finish
