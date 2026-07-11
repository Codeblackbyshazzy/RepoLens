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

# Tests for issue #385: task-complexity estimation (1-5) threaded through the
# finding registry. Complexity is a NEW orthogonal, OPTIONAL, nullable numeric
# field that rides the exact rails `confidence` already uses:
#   - build_findings_jsonl_from_local reads a `complexity:` frontmatter scalar,
#     normalizes it to an integer 1..5 (else null), and stores it in the record.
#   - build_findings_jsonl_from_manifest reads `.complexity` from a cluster and
#     stores it the same way.
#   - build_findings_csv projects complexity as a column (empty cell when null).
#   - validate_findings_jsonl accepts an absent/null/in-range complexity and
#     REJECTS an out-of-range or non-integer complexity — but never REQUIRES it
#     (mirrors `confidence`, which is present-but-null on every record today).
#
# Pure JSONL/CSV/frontmatter transforms; NO AI models are invoked. The model
# AUTHORS the estimate upstream (prompts) — this suite only exercises the bash
# parse/store/project/validate layer, which is the only model-free surface.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-ledger-complexity"
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
    fail_with "$desc" "Expected non-zero exit, got 0"
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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in: $haystack"
  fi
}

# assert_eq <desc> <expected> <actual>
#   Exact string equality — used for the direct normalizer unit tests, matching
#   the signature the sibling ledger tests use for _ledger_severity_normalize /
#   _ledger_finding_type_normalize.
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected [$expected], got [$actual]"
  fi
}

# assert_jq <desc> <jq-filter> <json-string>
#   Passes when `jq -e <filter>` over the JSON string on stdin exits 0.
assert_jq() {
  local desc="$1" filter="$2" subject="$3"
  TOTAL=$((TOTAL + 1))
  if jq -e "$filter" <<<"$subject" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq filter failed: $filter"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source lib/ledger.sh ALONE (must stay self-contained) -----------------
# Every complexity surface lives in ledger.sh (the three builders + validator),
# which must keep sourcing on its own (no hard dep on core/logging). Sourcing
# alone here doubles as the TDD red-phase guard: if the file/functions vanish we
# fail with one clear message instead of a cascade.
TOTAL=$((TOTAL + 1))
if [[ -f "$LEDGER_LIB" ]]; then
  pass_with "lib/ledger.sh exists"
else
  fail_with "lib/ledger.sh exists" "missing: $LEDGER_LIB"
  finish
fi

# shellcheck source=/dev/null
source "$LEDGER_LIB"

for fn in build_findings_jsonl_from_local build_findings_jsonl_from_manifest \
          build_findings_csv validate_findings_jsonl; do
  TOTAL=$((TOTAL + 1))
  if declare -F "$fn" >/dev/null 2>&1; then
    pass_with "$fn is defined after sourcing ledger alone"
  else
    fail_with "$fn is defined after sourcing ledger alone" \
      "function not found — implementation pending (TDD red phase)"
    finish
  fi
done

# ---------------------------------------------------------------------------
# Helpers that produce a single registry record via each builder, so the
# per-case assertions stay one-liners.
# ---------------------------------------------------------------------------

# emit_local_record <slug> <complexity-line-or-empty>
#   Writes ONE --local finding markdown with the given `complexity:` frontmatter
#   line (pass "" to omit it entirely), runs build_findings_jsonl_from_local,
#   and prints the single JSONL record it produced.
emit_local_record() {
  local slug="$1" cxline="$2"
  local dir="$TMPDIR/local-$slug"
  mkdir -p "$dir/code/example"
  {
    printf '%s\n' '---'
    printf '%s\n' "title: \"[high] Local case $slug\""
    printf '%s\n' 'severity: high'
    printf '%s\n' 'domain: code'
    printf '%s\n' 'lens: example'
    [[ -n "$cxline" ]] && printf '%s\n' "$cxline"
    printf '%s\n' '---'
    printf '%s\n' 'Body text.'
  } > "$dir/code/example/001-case.md"
  local out="$TMPDIR/local-$slug.jsonl"
  build_findings_jsonl_from_local "$dir" "$out" >/dev/null 2>&1
  [[ -f "$out" ]] && cat "$out"
}

# emit_manifest_record <slug> <complexity-json-or-"omit">
#   Writes a one-cluster synthesizer manifest carrying the given complexity
#   value (or none when "omit"), runs build_findings_jsonl_from_manifest, and
#   prints the single record.
emit_manifest_record() {
  local slug="$1" cx="$2"
  local man="$TMPDIR/manifest-$slug.json" out="$TMPDIR/manifest-$slug.jsonl"
  if [[ "$cx" == "omit" ]]; then
    jq -n --arg s "$slug" \
      '[{cluster_id:("c-"+$s),title:("Manifest case "+$s),severity:"high",domain:"code",lens:"example"}]' \
      > "$man"
  else
    jq -n --arg s "$slug" --argjson cx "$cx" \
      '[{cluster_id:("c-"+$s),title:("Manifest case "+$s),severity:"high",domain:"code",lens:"example",complexity:$cx}]' \
      > "$man"
  fi
  build_findings_jsonl_from_manifest "$man" "$out" >/dev/null 2>&1
  [[ -f "$out" ]] && cat "$out"
}

# wellformed_record <id-suffix> <complexity-json-or-"omit">
#   A fully-formed registry line (all 12 required keys) with complexity added
#   (or omitted). Used to drive validate_findings_jsonl and build_findings_csv.
wellformed_record() {
  local idn="$1" cx="$2"
  if [[ "$cx" == "omit" ]]; then
    jq -cn --arg id "fnd-cx$idn" \
      '{id:$id,title:"Complexity case",severity:"high",type:"security",domain:"code",lens:"input-validation",status:"new",primary_location:"",confidence:null,duplicate_group:null,markdown_path:null,validation:{}}'
  else
    jq -cn --arg id "fnd-cx$idn" --argjson cx "$cx" \
      '{id:$id,title:"Complexity case",severity:"high",type:"security",domain:"code",lens:"input-validation",status:"new",primary_location:"",confidence:null,duplicate_group:null,markdown_path:null,validation:{},complexity:$cx}'
  fi
}

VAL_N=0
VAL_RC=0
VAL_ERR=""
# validate_record <json-line>
#   Runs validate_findings_jsonl over a one-line registry; sets VAL_RC / VAL_ERR.
validate_record() {
  VAL_N=$((VAL_N + 1))
  local f="$TMPDIR/validate-$VAL_N.jsonl"
  printf '%s\n' "$1" > "$f"
  validate_findings_jsonl "$f" 2>"$TMPDIR/validate-$VAL_N.err"
  VAL_RC=$?
  VAL_ERR="$(cat "$TMPDIR/validate-$VAL_N.err")"
}

# ===========================================================================
echo "=== _ledger_complexity_normalize: direct branch coverage ==="
# ===========================================================================
# The normalizer is the single reused primitive every builder delegates to, so
# its discrete branches (de-quote, trim, integer/range gate, reject-to-empty)
# deserve direct coverage — mirroring how the sibling _ledger_severity_normalize
# and _ledger_finding_type_normalize are unit-tested. The builder sections below
# only exercise a couple of these paths through the full pipeline; here we pin
# each branch in isolation with a clear failure message.
TOTAL=$((TOTAL + 1))
if declare -F _ledger_complexity_normalize >/dev/null 2>&1; then
  pass_with "_ledger_complexity_normalize is defined"
else
  fail_with "_ledger_complexity_normalize is defined" "normalizer helper not found"
  finish
fi

# Bare in-range integers pass through unchanged, including both boundaries.
assert_eq "normalize: bare 1 -> 1 (lower boundary)"   "1" "$(_ledger_complexity_normalize 1)"
assert_eq "normalize: bare 3 -> 3"                    "3" "$(_ledger_complexity_normalize 3)"
assert_eq "normalize: bare 5 -> 5 (upper boundary)"   "5" "$(_ledger_complexity_normalize 5)"

# Quote stripping: BOTH double and single quotes are removed (YAML may quote the
# scalar either way). The double-quote path is exercised indirectly by the local
# builder's "5" case; the single-quote path is only covered here.
assert_eq "normalize: double-quoted \"4\" -> 4" "4" "$(_ledger_complexity_normalize '"4"')"
assert_eq "normalize: single-quoted '2' -> 2"  "2" "$(_ledger_complexity_normalize "'2'")"

# Surrounding whitespace is trimmed (frontmatter values can carry padding).
assert_eq "normalize: whitespace-padded '  3  ' -> 3" "3" "$(_ledger_complexity_normalize '  3  ')"

# Everything outside the closed 1..5 integer set rejects to "" (stored as null):
# out-of-range, non-integer, non-numeric, descriptor-suffixed, and odd numeric
# forms (leading zero / signs) — the gate is an EXACT digit match, not a lenient
# integer parse, so these must not slip through as a false-legal tier.
assert_eq "normalize: 0 -> '' (below range)"                 "" "$(_ledger_complexity_normalize 0)"
assert_eq "normalize: 6 -> '' (above range)"                 "" "$(_ledger_complexity_normalize 6)"
assert_eq "normalize: 2.5 -> '' (non-integer)"               "" "$(_ledger_complexity_normalize 2.5)"
assert_eq "normalize: 'high' -> '' (non-numeric)"            "" "$(_ledger_complexity_normalize high)"
assert_eq "normalize: '3 (Medium)' -> '' (descriptor text)"  "" "$(_ledger_complexity_normalize '3 (Medium)')"
assert_eq "normalize: '05' -> '' (leading zero)"             "" "$(_ledger_complexity_normalize 05)"
assert_eq "normalize: empty string -> ''"                    "" "$(_ledger_complexity_normalize '')"

# set -u safety: called with NO argument (the ${1:-} guard) must not abort under
# set -u and must return "" — the normalizer is invoked in contexts where the
# frontmatter/manifest value may be entirely absent.
assert_eq "normalize: missing argument -> '' (set -u safe)" "" "$(_ledger_complexity_normalize)"

# ===========================================================================
echo "=== build_findings_jsonl_from_local: complexity frontmatter -> record ==="
# ===========================================================================

# In-range integer is stored as a JSON NUMBER (not a string) — downstream model
# routers key on a numeric tier, so the type matters as much as the value.
rec="$(emit_local_record inrange 'complexity: 3')"
assert_jq "local: complexity 3 is stored as the number 3" \
  'has("complexity") and (.complexity | type) == "number" and .complexity == 3' "$rec"

# A YAML-quoted boundary value still de-quotes + normalizes (the frontmatter
# reader keeps the quotes; the value pipeline must strip them like it does for
# `title`). 5 is the top of the scale.
rec="$(emit_local_record quoted 'complexity: "5"')"
assert_jq "local: quoted complexity \"5\" normalizes to the number 5" \
  'has("complexity") and .complexity == 5' "$rec"

# Optional: a finding WITHOUT a complexity line still carries the key, set to
# null (present-but-null, exactly like `confidence`). has() is asserted so this
# fails in the red phase — an absent key would trivially satisfy `== null`.
rec="$(emit_local_record absent '')"
assert_jq "local: absent complexity frontmatter yields complexity:null (key present)" \
  'has("complexity") and .complexity == null' "$rec"

# Out-of-range is REJECTED to null, not silently clamped — masking a
# miscalibrated model as a legal 5 would corrupt routing.
rec="$(emit_local_record over 'complexity: 7')"
assert_jq "local: out-of-range-high complexity 7 -> null" \
  'has("complexity") and .complexity == null' "$rec"

rec="$(emit_local_record under 'complexity: 0')"
assert_jq "local: out-of-range-low complexity 0 -> null" \
  'has("complexity") and .complexity == null' "$rec"

# The local builder's output must still pass the registry validator (the field
# it now emits has to be one the validator accepts).
validate_findings_jsonl "$TMPDIR/local-inrange.jsonl" 2>/dev/null
assert_success "local: a record carrying complexity still validates" "$?"

# ===========================================================================
echo "=== build_findings_jsonl_from_manifest: .complexity -> record ==="
# ===========================================================================

rec="$(emit_manifest_record inrange 4)"
assert_jq "manifest: complexity 4 is stored as the number 4" \
  'has("complexity") and (.complexity | type) == "number" and .complexity == 4' "$rec"

rec="$(emit_manifest_record absent omit)"
assert_jq "manifest: a cluster without complexity yields complexity:null (key present)" \
  'has("complexity") and .complexity == null' "$rec"

rec="$(emit_manifest_record over 9)"
assert_jq "manifest: out-of-range complexity 9 -> null" \
  'has("complexity") and .complexity == null' "$rec"

# A manifest may carry complexity as a JSON STRING ("3") rather than a bare
# number — the builder reads `.complexity // "" | tostring` defensively so a
# string and a number both reach the normalizer as bare digits. Confirm the
# string form still lands as the NUMBER 3 (downstream routers key on numeric
# type), exercising the tostring path the numeric cases above skip.
rec="$(emit_manifest_record strnum '"3"')"
assert_jq "manifest: string-typed complexity \"3\" normalizes to the number 3" \
  'has("complexity") and (.complexity | type) == "number" and .complexity == 3' "$rec"

# ===========================================================================
echo "=== build_findings_csv: complexity projects as a column ==="
# ===========================================================================

csv_in="$TMPDIR/complexity.jsonl"
{ wellformed_record 001 2; wellformed_record 002 null; } > "$csv_in"
csv_out="$TMPDIR/complexity.csv"
build_findings_csv "$csv_in" "$csv_out"
assert_success "csv: build over a registry with complexity returns 0" "$?"
assert_file_exists "csv: output file is created" "$csv_out"

csv_header=""
IFS= read -r csv_header < "$csv_out"
assert_contains "csv: header row carries a complexity column" "complexity" "$csv_header"

# Authoritative value check with a real RFC-4180 parser: complexity is a column,
# a numeric complexity renders as its digits, and a null complexity is an empty
# cell (parity with how null confidence already renders). Guarded — python3 is
# not a hard test dependency; the header assertion above still covers the
# column-presence contract without it.
if command -v python3 >/dev/null 2>&1; then
  py_rc=0
  python3 - "$csv_out" <<'PYEOF' || py_rc=$?
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], newline='')))
fieldnames = rows[0].keys() if rows else []
if 'complexity' not in fieldnames:
    sys.stderr.write('no complexity column: %r\n' % (list(fieldnames),))
    sys.exit(1)
if len(rows) != 2:
    sys.stderr.write('expected 2 rows, got %d\n' % len(rows))
    sys.exit(1)
# Row 1 has complexity 2; a JSON number projects as its bare digits.
if rows[0]['complexity'] != '2':
    sys.stderr.write('row0 complexity: %r\n' % rows[0]['complexity'])
    sys.exit(1)
# Row 2 has complexity null; a null projects as an empty cell.
if rows[1]['complexity'] != '':
    sys.stderr.write('row1 complexity should be empty, got %r\n' % rows[1]['complexity'])
    sys.exit(1)
sys.exit(0)
PYEOF
  assert_success "csv: python round-trip — complexity column, number & null->empty" "$py_rc"
else
  echo "  NOTE: python3 not found — skipping the csv complexity round-trip check" \
       "(header column-presence assertion above still covers the contract)"
fi

# ===========================================================================
echo "=== validate_findings_jsonl: complexity is optional + range-checked ==="
# ===========================================================================

# Absent complexity must NOT be rejected — it is OPTIONAL, never a required key
# (the single biggest regression risk: adding it to the required-keys list).
validate_record "$(wellformed_record v-absent omit)"
assert_success "validate: a record with NO complexity key is accepted" "$VAL_RC"

# Explicit null is accepted (present-but-null, the builder's default).
validate_record "$(wellformed_record v-null null)"
assert_success "validate: complexity:null is accepted" "$VAL_RC"

# The full in-range set (both boundaries + a mid value) is accepted.
{
  wellformed_record v-lo 1
  wellformed_record v-mid 3
  wellformed_record v-hi 5
} > "$TMPDIR/valid-range.jsonl"
validate_findings_jsonl "$TMPDIR/valid-range.jsonl" 2>/dev/null
assert_success "validate: complexity 1, 3 and 5 all accepted (inclusive range)" "$?"

# Out-of-range HIGH is rejected and the message names the offending field.
validate_record "$(wellformed_record v-over 6)"
assert_failure "validate: complexity 6 is rejected" "$VAL_RC"
assert_contains "validate: the 6-is-invalid error names complexity" "complexity" "$VAL_ERR"

# Out-of-range LOW is rejected.
validate_record "$(wellformed_record v-under 0)"
assert_failure "validate: complexity 0 is rejected" "$VAL_RC"

# A non-integer in range is rejected — the scale is 1..5 whole steps, and a
# fractional tier is meaningless to a router.
validate_record "$(wellformed_record v-frac 2.5)"
assert_failure "validate: non-integer complexity 2.5 is rejected" "$VAL_RC"

# A non-NUMBER complexity is rejected — a stored complexity must be a JSON number
# (the builders always emit a number or null). A string-typed "3" that slipped in
# from a hand-authored/corrupt record must not validate: this exercises the
# `type != "number"` guard, distinct from the range (6/0) and floor (2.5) guards
# above, and the error still names the offending field.
validate_record "$(wellformed_record v-str '"3"')"
assert_failure "validate: string-typed complexity \"3\" is rejected" "$VAL_RC"
assert_contains "validate: the string-complexity error names complexity" "complexity" "$VAL_ERR"

finish
