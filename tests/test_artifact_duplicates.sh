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

# Tests for issue #330: generate final/DUPLICATES.md from findings.jsonl
# (the "N lenses converged on the same finding" list — a confidence signal).
# Pure-function tests only; NO AI models are invoked — all input is handwritten
# JSON-Lines fixtures (CLAUDE.md hard rule).
#
# Contract under test (issue #330 acceptance criteria + the owner's research
# comment, which is the authoritative spec for the open design calls — the same
# convention the sibling test_artifact_needs_review.sh / test_artifact_todo.sh
# test-dev stages follow):
#
#   generate_duplicates_md <findings_jsonl> <out_file>
#     Reads the finding registry (JSON Lines, schema in
#     docs/finding-registry-schema.md) and writes a Markdown file at <out_file>.
#     One section per MERGED GROUP: the canonical finding (severity, type,
#     primary_location, link to its markdown_path) followed by the other lenses
#     that also reported it (its `also_reported_by` list).
#
#   MERGED-GROUP PREDICATE — research "Reading A" (the recommended/owner design,
#   §5a). A merged group <=> a record whose `also_reported_by` is a NON-EMPTY
#   ARRAY; that record IS the canonical, and its array already enumerates the
#   other reporters. The reporter count = 1 + (also_reported_by | length).
#   `duplicate_group` is the section's group identity/anchor (AC#1 "grouped by
#   duplicate_group"), but the reporter list is read from `also_reported_by`
#   (AC#2). This is robust to today's data (where `also_reported_by` is not yet
#   carried into findings.jsonl — see research §3 — so it yields ZERO groups and
#   the clean empty-state path) and lights up automatically once the carry-through
#   lands. Grouping NEVER depends on the `duplicate_group` value, so a
#   null/missing `duplicate_group` cannot crash the generator (AC#4).
#
#   SINGLETONS — EXCLUDED (research §5b, the documented rule). DUPLICATES.md is
#   ABOUT convergence; a singleton has nothing to merge and already appears in
#   TODO.md / NEEDS_REVIEW.md. A record with no / empty / non-array
#   `also_reported_by` is a singleton and is excluded by definition.
#
#   Shape of each `also_reported_by[]` element (research §4, from
#   lib/synthesize.sh::_synthesize_attach_also_reported_by): one element per
#   non-canonical contributor, each { "lens": <id>, "domain": <id>,
#   "markdown_path": <path> } (markdown_path may be "").
#
# Design notes that shape these tests (test-dev discipline — mirrors the sibling):
#   - We test PUBLIC behavior: the contents of the written file and the return
#     code — never the internal jq filter / helper names / exact layout.
#   - The function is expected in lib/artifacts.sh (next to generate_todo_md /
#     generate_needs_review_md, per research §6), with a lib/summary.sh fallback.
#     We source whichever defines generate_duplicates_md and assert on the
#     FUNCTION, not the file.
#   - For "also reported by" rendering we assert the contributor LENS IDS appear
#     at/after the canonical title — distinctive tokens (e.g. "secret-scan",
#     "race-detector") that prove the convergence list rendered without pinning
#     the exact "domain/lens" join or the "N other lens(es)" phrasing (the
#     implementer's documented wording choice).
#   - The empty-PRESENT-file / all-excluded return code and the exact empty-state
#     note text are NOT pinned here (research sanctions rc 0 + empty-state); only
#     "no spurious entries, no crash" is asserted. The MISSING / bad-arg input rc
#     IS pinned non-zero — issue scope ("does not error the caller" via a clean
#     return) and research ("return 2, nothing written") agree it is a clean
#     non-zero return with no output file. (Threshold/format/empty-state pinning
#     is deliberately left to the coverage stage, exactly as the siblings did.)

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

TMP_PARENT="$SCRIPT_DIR/logs/test-artifact-duplicates"
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
#   line that holds <anchor>. Used to attribute a contributor lens to a specific
#   canonical entry: anchoring on the canonical's unique title isolates that
#   section from the file header. With one merged group per fixture, "from the
#   title onward" is exactly that group's section. Both matched literally.
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
  GEN_OUT="$TMPDIR/duplicates-$GEN_N.md"
  GEN_ERR="$TMPDIR/err-$GEN_N.txt"
  printf '%s' "$content" >"$GEN_IN"
  generate_duplicates_md "$GEN_IN" "$GEN_OUT" 2>"$GEN_ERR"
  GEN_RC=$?
}

# run_gen_missing — invoke the generator against an input path that does not
#   exist (the "missing input" edge). Captures GEN_OUT / GEN_ERR / GEN_RC.
run_gen_missing() {
  GEN_N=$((GEN_N + 1))
  GEN_OUT="$TMPDIR/duplicates-$GEN_N.md"
  GEN_ERR="$TMPDIR/err-$GEN_N.txt"
  generate_duplicates_md "$TMPDIR/does-not-exist-$GEN_N.jsonl" "$GEN_OUT" 2>"$GEN_ERR"
  GEN_RC=$?
}

# --- Source the library (core.sh + risk.sh first; the generator MAY reuse the
# shared severity/risk helpers, and sourcing them is harmless if it does not).
# Prefer lib/artifacts.sh (research recommendation, alongside the siblings); fall
# back to lib/summary.sh. Assert on the FUNCTION, not the file. ----------------
# shellcheck source=/dev/null
[[ -f "$CORE_LIB" ]] && source "$CORE_LIB"
# shellcheck source=/dev/null
[[ -f "$RISK_LIB" ]] && source "$RISK_LIB"
if [[ -f "$ARTIFACTS_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$ARTIFACTS_LIB"
fi
if ! declare -F generate_duplicates_md >/dev/null 2>&1 && [[ -f "$SUMMARY_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$SUMMARY_LIB"
fi

TOTAL=$((TOTAL + 1))
if declare -F generate_duplicates_md >/dev/null 2>&1; then
  pass_with "generate_duplicates_md is defined after sourcing (artifacts.sh or summary.sh)"
else
  fail_with "generate_duplicates_md is defined after sourcing (artifacts.sh or summary.sh)" \
    "not found in lib/artifacts.sh or lib/summary.sh"
  finish
fi

# ===========================================================================
# AC#1 + AC#2: a multi-reporter merged group renders the canonical finding
# (severity, type, primary_location, markdown_path link) followed by the other
# lenses that also reported it. ONE canonical record carrying a 2-element
# `also_reported_by`; assert the canonical fields render and BOTH contributor
# lens ids appear at/after the canonical title.
# ===========================================================================
read -r -d '' FIX_MULTI <<'EOF' || true
{"id":"c1","title":"CANON-MULTI","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"src/app.sh:42","confidence":0.9,"duplicate_group":"g1","markdown_path":"001-canonical.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"003-secret.md"},{"lens":"race-detector","domain":"reliability","markdown_path":"004-race.md"}],"validation":{}}
EOF
run_gen "$FIX_MULTI"
assert_rc_zero        "multi-reporter group -> success rc" "$GEN_RC"
assert_file_exists    "multi-reporter group writes a Markdown file at out_file" "$GEN_OUT"
assert_nonempty       "multi-reporter group output is non-empty" "$GEN_OUT"
assert_contains       "merged group shows the canonical title" "CANON-MULTI" "$GEN_OUT"
assert_contains_ci    "merged group shows the canonical severity" "high" "$GEN_OUT"
assert_contains       "merged group shows the canonical type" "security" "$GEN_OUT"
assert_contains       "merged group shows the canonical primary_location" "src/app.sh:42" "$GEN_OUT"
assert_contains       "merged group links to the canonical markdown_path" "](001-canonical.md)" "$GEN_OUT"
assert_contains_after "also-reported-by lists the first contributor lens"  "CANON-MULTI" "secret-scan"   "$GEN_OUT"
assert_contains_after "also-reported-by lists the second contributor lens" "CANON-MULTI" "race-detector" "$GEN_OUT"
# Coverage stage (test-dev deferred these): pin the OTHER-lens COUNT phrasing, the
# domain/lens JOIN format, and the per-contributor markdown_path link. The count is
# a DERIVED value (number of also_reported_by elements, i.e. the OTHER reporters);
# pinning "2" for a 2-element list guards against an off-by-one (e.g. 1+N total) or
# a hardcoded constant. The join pairs each lens with its OWN domain — pinning both
# joins guards against a domain/lens mismatch. The contributor link proves each
# also_reported_by element renders its own markdown_path (only the CANONICAL link
# was pinned before).
assert_contains "merged group reports the OTHER-lens count (2 contributors)" "2 other lens(es)" "$GEN_OUT"
assert_contains "first contributor renders as domain/lens"  "security/secret-scan"    "$GEN_OUT"
assert_contains "second contributor renders as domain/lens" "reliability/race-detector" "$GEN_OUT"
assert_contains "first contributor links its own markdown_path"  "](003-secret.md)" "$GEN_OUT"
assert_contains "second contributor links its own markdown_path" "](004-race.md)"   "$GEN_OUT"

# ===========================================================================
# AC#3: singleton groups are EXCLUDED (the documented rule). A record with no
# `also_reported_by` has nothing to merge. Mixed fixture: one merged group + one
# singleton -> the merged canonical renders, the singleton title is absent (proven
# while the file is non-empty, so absence is exclusion, not an empty file).
# ===========================================================================
read -r -d '' FIX_SINGLETON <<'EOF' || true
{"id":"c2","title":"CANON-KEEP","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"k.sh:1","confidence":0.9,"duplicate_group":"g2","markdown_path":"010-keep.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"011-x.md"}],"validation":{}}
{"id":"s1","title":"SINGLE-DROP","severity":"critical","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"s.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"012-single.md","validation":{}}
EOF
run_gen "$FIX_SINGLETON"
assert_rc_zero      "merged+singleton fixture -> success rc" "$GEN_RC"
assert_no_crash     "merged+singleton fixture does not crash the caller" "$GEN_ERR"
assert_contains     "the merged group's canonical still renders" "CANON-KEEP" "$GEN_OUT"
assert_not_contains "a singleton (no also_reported_by) is EXCLUDED" "SINGLE-DROP" "$GEN_OUT"
# Coverage stage: a group with a SINGLE other reporter renders "1 other lens(es)".
# Paired with the "2 other lens(es)" pin above, this confirms the count tracks the
# also_reported_by length rather than being hardcoded.
assert_contains     "single-contributor group reports the count (1)" "1 other lens(es)" "$GEN_OUT"

# ===========================================================================
# AC#4: null / missing `duplicate_group` does not crash the generator. Grouping
# is driven off `also_reported_by` (Reading A), so the group anchor value is
# irrelevant to whether the group renders. One canonical with a non-empty
# `also_reported_by` and `duplicate_group:null`; a second with the
# `duplicate_group` key absent entirely. Both must render, no crash, and the
# literal "null" must not leak into the Markdown.
# ===========================================================================
read -r -d '' FIX_NULLGROUP <<'EOF' || true
{"id":"n1","title":"NULLGRP-A","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"a.sh:1","confidence":0.9,"duplicate_group":null,"markdown_path":"020-a.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"021-x.md"}],"validation":{}}
{"id":"n2","title":"NULLGRP-B","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"b.sh:1","confidence":0.9,"markdown_path":"022-b.md","also_reported_by":[{"lens":"race-detector","domain":"reliability","markdown_path":"023-y.md"}],"validation":{}}
EOF
run_gen "$FIX_NULLGROUP"
assert_rc_zero      "null/missing duplicate_group -> success rc (no crash)" "$GEN_RC"
assert_no_crash     "null/missing duplicate_group does not crash the caller" "$GEN_ERR"
assert_contains     "merged group with null duplicate_group still renders" "NULLGRP-A" "$GEN_OUT"
assert_contains     "merged group with absent duplicate_group key still renders" "NULLGRP-B" "$GEN_OUT"
assert_not_contains "null duplicate_group does not leak the literal \"null\"" "null" "$GEN_OUT"

# ===========================================================================
# Defensive rendering: a canonical with type:null, primary_location:"", and
# markdown_path:null (plus an also_reported_by element whose markdown_path is "")
# must not leak the literal "null" and must not emit a broken empty link "[...]()";
# the merged group still appears with its contributor lens.
# ===========================================================================
read -r -d '' FIX_DEFENSIVE <<'EOF' || true
{"id":"d1","title":"DEFENSIVE-DUP","severity":"high","type":null,"domain":"security","lens":"sast","status":"new","primary_location":"","confidence":null,"duplicate_group":"g3","markdown_path":null,"also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":""}],"validation":{}}
EOF
run_gen "$FIX_DEFENSIVE"
assert_rc_zero      "defensive fixture -> success rc" "$GEN_RC"
assert_no_crash     "sparse-field merged group does not crash the caller" "$GEN_ERR"
assert_contains     "merged group with sparse fields still appears" "DEFENSIVE-DUP" "$GEN_OUT"
assert_contains     "sparse merged group still lists its contributor lens" "secret-scan" "$GEN_OUT"
assert_not_contains "null fields do not leak the literal \"null\" into the Markdown" "null" "$GEN_OUT"
assert_not_contains "null/empty markdown_path does not emit a broken empty link \"[...]()\"" "]()" "$GEN_OUT"

# ===========================================================================
# Defensive grouping: a non-array / null / absent `also_reported_by` degrades to
# a singleton (no-match) — never crash, never invent a group. Direct analogue of
# the sibling's `vobj` guard test. Three records: also_reported_by as a string /
# null / absent. All three are excluded; the file does not crash.
# ===========================================================================
read -r -d '' FIX_BADARB <<'EOF' || true
{"id":"b1","title":"ARB-STRING","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"a.sh:1","confidence":0.9,"duplicate_group":"g4","markdown_path":"030-a.md","also_reported_by":"secret-scan","validation":{}}
{"id":"b2","title":"ARB-NULL","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"b.sh:1","confidence":0.9,"duplicate_group":"g5","markdown_path":"031-b.md","also_reported_by":null,"validation":{}}
{"id":"b3","title":"ARB-ABSENT","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"c.sh:1","confidence":0.9,"duplicate_group":"g6","markdown_path":"032-c.md","validation":{}}
EOF
run_gen "$FIX_BADARB"
assert_rc_zero      "non-array/null/absent also_reported_by -> success rc" "$GEN_RC"
assert_no_crash     "non-array/null/absent also_reported_by does not crash the caller" "$GEN_ERR"
assert_not_contains "a string also_reported_by degrades to a singleton (EXCLUDED)" "ARB-STRING" "$GEN_OUT"
assert_not_contains "a null also_reported_by degrades to a singleton (EXCLUDED)" "ARB-NULL" "$GEN_OUT"
assert_not_contains "an absent also_reported_by key degrades to a singleton (EXCLUDED)" "ARB-ABSENT" "$GEN_OUT"
# Coverage stage (test-dev deferred the empty-PRESENT-file contract now that the code
# chose rc 0 + a written file + an empty-state note). With every record excluded the
# generator must still write a valid present file carrying the empty-state note — a
# regression to "write nothing / error out" would be caught here. (rc 0 already
# asserted above for this fixture.)
assert_file_exists  "all-excluded registry still writes a present file" "$GEN_OUT"
assert_contains     "all-excluded registry carries the empty-state note" "No duplicate groups" "$GEN_OUT"

# ===========================================================================
# AC (research §5c): order merged groups by severity (critical > high > low).
# All three qualify (each carries a non-empty also_reported_by); input order
# scrambled so a pass proves the generator sorts rather than echoing input order.
# ===========================================================================
read -r -d '' FIX_ORDER <<'EOF' || true
{"id":"o1","title":"ORD-LOW","severity":"low","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"l.sh:1","confidence":0.9,"duplicate_group":"g7","markdown_path":"040-low.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"041-x.md"}],"validation":{}}
{"id":"o2","title":"ORD-CRIT","severity":"critical","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"c.sh:1","confidence":0.9,"duplicate_group":"g8","markdown_path":"042-crit.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"043-y.md"}],"validation":{}}
{"id":"o3","title":"ORD-HIGH","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"h.sh:1","confidence":0.9,"duplicate_group":"g9","markdown_path":"044-high.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"045-z.md"}],"validation":{}}
EOF
run_gen "$FIX_ORDER"
assert_rc_zero "ordering fixture -> success rc" "$GEN_RC"
assert_before  "ordering: critical group precedes high group" "ORD-CRIT" "ORD-HIGH" "$GEN_OUT"
assert_before  "ordering: high group precedes low group"      "ORD-HIGH" "ORD-LOW"  "$GEN_OUT"

# ===========================================================================
# Determinism: the same input rendered twice produces byte-identical output (a
# stable sort tiebreak — required so finalize output does not churn run-to-run).
# Reuses the order fixture's input ($GEN_IN from the last run_gen).
# ===========================================================================
DET_OUT_A="$TMPDIR/det-a.md"
DET_OUT_B="$TMPDIR/det-b.md"
generate_duplicates_md "$GEN_IN" "$DET_OUT_A" 2>/dev/null
generate_duplicates_md "$GEN_IN" "$DET_OUT_B" 2>/dev/null
TOTAL=$((TOTAL + 1))
if cmp -s "$DET_OUT_A" "$DET_OUT_B"; then
  pass_with "deterministic: two runs on the same input are byte-identical"
else
  fail_with "deterministic: two runs on the same input are byte-identical" "outputs differ"
fi

# ===========================================================================
# Coverage stage: within the SAME severity, groups order by confidence DESCENDING,
# and a null confidence degrades to the 0.5 neutral midpoint (sorting between a high
# and a low confidence). All three are "high" severity so confidence is the deciding
# key; input order is scrambled so a pass proves the sort, not echoed input order.
# This exercises the confidence sort key and its null->0.5 fallback's ORDERING
# effect (the existing defensive fixture only proved null confidence does not crash).
# ===========================================================================
read -r -d '' FIX_CONF <<'EOF' || true
{"id":"cf1","title":"CONF-LOW","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"l.sh:1","confidence":0.3,"duplicate_group":"gc1","markdown_path":"cl.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"x.md"}],"validation":{}}
{"id":"cf2","title":"CONF-MID","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"m.sh:1","confidence":null,"duplicate_group":"gc2","markdown_path":"cm.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"y.md"}],"validation":{}}
{"id":"cf3","title":"CONF-HIGH","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"h.sh:1","confidence":0.95,"duplicate_group":"gc3","markdown_path":"ch.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"z.md"}],"validation":{}}
EOF
run_gen "$FIX_CONF"
assert_rc_zero "confidence-ordering fixture -> success rc" "$GEN_RC"
assert_before  "same severity: higher confidence precedes null (0.5 neutral)" "CONF-HIGH" "CONF-MID" "$GEN_OUT"
assert_before  "same severity: null (0.5 neutral) precedes lower confidence"  "CONF-MID"  "CONF-LOW" "$GEN_OUT"

# ===========================================================================
# Injection safety: a merged group whose canonical title is packed with shell-
# and Markdown-significant characters must render VERBATIM — no command
# substitution runs, the pipe survives (list layout, not a table), and the
# structured fields still render. (Mirrors the sibling generators' guarantee.)
# ===========================================================================
read -r -d '' FIX_INJECT <<'EOF' || true
{"id":"i1","title":"INJ-DUP |pipe `backtick` $(echo NOTRUN) ]rbracket","severity":"high","type":"security","domain":"security","lens":"sast","status":"new","primary_location":"inj.sh:1","confidence":0.9,"duplicate_group":"g10","markdown_path":"050-inj.md","also_reported_by":[{"lens":"secret-scan","domain":"security","markdown_path":"051-x.md"}],"validation":{}}
EOF
run_gen "$FIX_INJECT"
assert_rc_zero  "special-char title -> success rc" "$GEN_RC"
assert_no_crash "special-char title does not crash the caller" "$GEN_ERR"
assert_contains "special-char title is rendered (group present)" "INJ-DUP" "$GEN_OUT"
assert_contains "command substitution in the title is NOT evaluated (verbatim \$(...) survives)" "\$(echo NOTRUN)" "$GEN_OUT"
assert_contains "a literal pipe in the title survives (list layout, no table breakage)" "|pipe" "$GEN_OUT"
assert_contains "the group's structured fields still render alongside the messy title" "inj.sh:1" "$GEN_OUT"

# ===========================================================================
# AC#5: empty input file (0 lines) produces no spurious entries and does not
# error the caller (no set -u explosion). Empty-PRESENT-file rc / empty-state
# text are NOT pinned here (coverage stage's job — see header).
# ===========================================================================
run_gen ""
assert_no_crash     "empty input file does not crash the caller" "$GEN_ERR"
assert_not_contains "empty input produces no spurious contributor lens" "secret-scan" "$GEN_OUT"
# Coverage stage: the implementation chose rc 0 + a written present file + an
# empty-state note for an empty-but-PRESENT registry (test-dev deferred pinning this).
# Lock all three so a future change cannot silently regress to erroring the caller or
# writing nothing — finalize relies on the file existing.
assert_rc_zero      "empty present file returns 0 (empty-state artifact)" "$GEN_RC"
assert_file_exists  "empty present file is still written" "$GEN_OUT"
assert_contains     "empty present file carries the empty-state note" "No duplicate groups" "$GEN_OUT"

# ===========================================================================
# AC#5: MISSING / unreadable input -> non-zero rc, no crash, nothing written.
# Issue scope ("does not error the caller" = clean return) and research
# ("return 2, nothing written") agree the rc is a clean non-zero.
# ===========================================================================
run_gen_missing
assert_rc_nonzero "missing input file -> non-zero rc" "$GEN_RC"
assert_no_crash   "missing input file does not crash the caller (clean return)" "$GEN_ERR"
TOTAL=$((TOTAL + 1))
if [[ ! -e "$GEN_OUT" ]]; then pass_with "missing input writes no output file"
else fail_with "missing input writes no output file" "Unexpected file $GEN_OUT"; fi

# ===========================================================================
# AC#5: an empty findings-path argument is a bad-arg shape -> non-zero rc, no
# crash, nothing written ("handles empty/missing input without erroring").
# ===========================================================================
BADARG_OUT="$TMPDIR/badarg-out.md"
BADARG_ERR="$TMPDIR/badarg.err"
generate_duplicates_md "" "$BADARG_OUT" 2>"$BADARG_ERR"; BADARG_RC=$?
assert_rc_nonzero "empty findings-path arg -> non-zero rc" "$BADARG_RC"
assert_no_crash   "empty findings-path arg does not crash the caller" "$BADARG_ERR"
TOTAL=$((TOTAL + 1))
if [[ ! -e "$BADARG_OUT" ]]; then pass_with "empty findings-path arg writes no output file"
else fail_with "empty findings-path arg writes no output file" "Unexpected file $BADARG_OUT"; fi

finish
