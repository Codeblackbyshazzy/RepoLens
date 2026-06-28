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

# Tests for issue #329: lib/ledger.sh — validate_findings_jsonl.
#
# A deterministic, last-line-of-defense validator for the canonical finding
# registry (findings.jsonl, schema in docs/finding-registry-schema.md). It
# checks each NON-empty line independently (JSON Lines, NOT a top-level array),
# so one malformed line cannot abort validation of the rest, and reports each
# violation to stderr prefixed with the 1-based line number — mirroring
# validate_manifest's stderr/return discipline. Per line it asserts: the line is
# a JSON object; the 12 required keys are present; id is a non-empty string;
# severity/status are in their enums; a non-null, non-empty type is in its enum
# (null/empty type accepted — owned by finding-types); validation is an object
# (internals NOT checked — owned by validation-hints). Extra/forward-compatible
# keys (e.g. source_finding_paths) are tolerated. Empty file -> 0.
#
# Pure jq + coreutils; NO AI models are invoked (CLAUDE.md "Tests" rule). Style
# mirrors tests/test_synthesize_validate_manifest.sh and tests/test_ledger_csv.sh.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-ledger-validate"
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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in: $haystack"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpectedly found '$needle' in: $haystack"
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
# validate_findings_jsonl needs only jq + coreutils, so ledger must still source
# on its own (no hard dep on lib/core.sh / synthesize.sh). Sourcing alone here
# proves that contract and doubles as the TDD red-phase guard: before the
# function exists we fail with one clear message instead of a cascade.
TOTAL=$((TOTAL + 1))
if [[ -f "$LEDGER_LIB" ]]; then
  pass_with "lib/ledger.sh exists"
else
  fail_with "lib/ledger.sh exists" "missing: $LEDGER_LIB"
  finish
fi

# shellcheck source=/dev/null
source "$LEDGER_LIB"

TOTAL=$((TOTAL + 1))
if declare -F validate_findings_jsonl >/dev/null 2>&1; then
  pass_with "validate_findings_jsonl is defined after sourcing ledger alone"
else
  fail_with "validate_findings_jsonl is defined after sourcing ledger alone" \
    "function not found — implementation pending (TDD red phase)"
  finish
fi

# ---------------------------------------------------------------------------
# Each compact JSON object below carries all 12 schema fields:
#   id, title, severity, type, domain, lens, status, primary_location,
#   confidence, duplicate_group, markdown_path, validation
# Fixtures are written with quoted heredocs ('EOF') so nothing is shell-expanded.
# ---------------------------------------------------------------------------

echo "=== validate_findings_jsonl: success paths ==="

# Case 1: well-formed fixture exercising the FULL enum space — every severity
# (critical/high/medium/low), every status (new/needs-validation/duplicate/
# likely-false-positive), type both null and several valid enum members, and
# validation both {} and a populated object. A correct validator accepts all of
# it; this proves no valid value is wrongly rejected.
wellformed="$TMPDIR/wellformed.jsonl"
cat > "$wellformed" <<'EOF'
{"id":"fnd-aaaaaa000001","title":"Validate upload filenames before writing","severity":"critical","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"lib/upload.sh:42","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-bbbbbb000002","title":"Reduce memory pressure in the worker pool","severity":"high","type":null,"domain":"code","lens":"memory","status":"needs-validation","primary_location":"","confidence":0.8,"duplicate_group":"grp-1","markdown_path":"final/002-memory.md","validation":{"proof_anchor":"lib/pool.sh:10","verdict":"plausible"}}
{"id":"fnd-cccccc000003","title":"Drop the redundant duplicate of parse_args","severity":"medium","type":"maintainability","domain":"code","lens":"duplicates","status":"duplicate","primary_location":"lib/args.sh:5","confidence":0.4,"duplicate_group":"grp-2","markdown_path":null,"validation":{}}
{"id":"fnd-dddddd000004","title":"Tidy a misleading README sentence","severity":"low","type":"reliability","domain":"docs","lens":"readme-quality","status":"likely-false-positive","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":"final/004-readme.md","validation":{}}
EOF
validate_findings_jsonl "$wellformed" 2>"$TMPDIR/wellformed.err"
status=$?
assert_success "well-formed multi-enum fixture returns 0" "$status"
assert_contains "well-formed fixture reports no errors" "" "$(cat "$TMPDIR/wellformed.err")"

# Case 2: empty file -> 0 (the explicit acceptance criterion). An empty registry
# is the canonical shape for a zero-finding run.
empty="$TMPDIR/empty.jsonl"
: > "$empty"
validate_findings_jsonl "$empty" 2>/dev/null
status=$?
assert_success "empty file returns 0" "$status"

# Case 3: type is null -> accepted (negative control for the AC "does NOT reject
# records where type is null"). The builder leaves type null initially.
type_null="$TMPDIR/type-null.jsonl"
cat > "$type_null" <<'EOF'
{"id":"fnd-type00000001","title":"Type is intentionally null","severity":"high","type":null,"domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$type_null" 2>/dev/null
status=$?
assert_success "record with type:null returns 0" "$status"

# Case 4: validation is {} -> accepted (negative control for the AC "does NOT
# reject records where validation is {}"). The builder emits validation:{}.
validation_empty="$TMPDIR/validation-empty.jsonl"
cat > "$validation_empty" <<'EOF'
{"id":"fnd-val000000001","title":"Validation slot is an empty object","severity":"medium","type":"performance","domain":"code","lens":"memory","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$validation_empty" 2>/dev/null
status=$?
assert_success "record with validation:{} returns 0" "$status"

# Case 5: extra/forward-compatible keys are tolerated. source_finding_paths is
# the real passthrough key the manifest builder emits; future_field is an
# arbitrary unknown key. Neither may cause a violation.
extra_keys="$TMPDIR/extra-keys.jsonl"
cat > "$extra_keys" <<'EOF'
{"id":"fnd-extra0000001","title":"Carries forward-compatible extra keys","severity":"low","type":"test-gap","domain":"code","lens":"coverage","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{},"source_finding_paths":["logs/run-1/rounds/round-1/lens-outputs/code/coverage.md"],"future_field":{"nested":true}}
EOF
validate_findings_jsonl "$extra_keys" 2>/dev/null
status=$?
assert_success "extra/forward-compatible keys are accepted" "$status"

# Case 5b (issue #344): the three CANONICAL LONG-FORM type ids that
# finding_resolve_type / finding_type_normalize emit must validate. The builders
# now write these (replacing type:null), and build_finding_registry validates
# BEFORE promoting — so if the enum ever drops a long id the whole registry build
# silently validates to nothing and promotes zero findings. This case is the
# regression lock for the additive enum reconciliation; the three short forms
# (security/reliability/performance) are already pinned by Case 1.
longform_types="$TMPDIR/longform-types.jsonl"
cat > "$longform_types" <<'EOF'
{"id":"fnd-long00000001","title":"Canonical long-form security id","severity":"critical","type":"security-vulnerability","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-long00000002","title":"Canonical long-form reliability id","severity":"high","type":"reliability-bug","domain":"code","lens":"memory","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-long00000003","title":"Canonical long-form performance id","severity":"medium","type":"performance-risk","domain":"code","lens":"perf","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-long00000004","title":"Shared-canonical maintainability id","severity":"low","type":"maintainability","domain":"docs","lens":"readme","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-long00000005","title":"Shared-canonical test-gap id","severity":"low","type":"test-gap","domain":"code","lens":"coverage","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-long00000006","title":"Shared-canonical external-dependency id","severity":"medium","type":"external-dependency","domain":"code","lens":"deps","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$longform_types" 2>"$TMPDIR/longform-types.err"
status=$?
assert_success "all six canonical long-form type ids validate (registry-build lock)" "$status"
assert_contains "long-form type fixture reports no errors" "" "$(cat "$TMPDIR/longform-types.err")"

echo ""
echo "=== validate_findings_jsonl: violation paths (with line numbers) ==="

# Case 6: a line that is a JSON array (valid JSON, but NOT an object) -> non-zero
# and the offending line number is reported.
not_object="$TMPDIR/not-object.jsonl"
cat > "$not_object" <<'EOF'
["this","is","an","array","not","an","object"]
EOF
validate_findings_jsonl "$not_object" 2>"$TMPDIR/not-object.err"
status=$?
not_object_err="$(cat "$TMPDIR/not-object.err")"
assert_failure "a JSON array line returns non-zero" "$status"
assert_contains "non-object error names the field shape (object)" "object" "$not_object_err"
assert_contains "non-object error reports line 1" "line 1" "$not_object_err"

# Case 7: an unparseable line (not valid JSON at all) -> non-zero, line reported.
# This exercises the jq parse-failure arm (distinct from the valid-but-non-object
# arm in Case 6); both must be caught.
bad_json="$TMPDIR/bad-json.jsonl"
cat > "$bad_json" <<'EOF'
{not valid json at all
EOF
validate_findings_jsonl "$bad_json" 2>"$TMPDIR/bad-json.err"
status=$?
bad_json_err="$(cat "$TMPDIR/bad-json.err")"
assert_failure "unparseable JSON line returns non-zero" "$status"
assert_contains "unparseable line reports line 1" "line 1" "$bad_json_err"

# Case 8: missing a required key (drop "severity") -> non-zero, line reported.
missing_key="$TMPDIR/missing-key.jsonl"
cat > "$missing_key" <<'EOF'
{"id":"fnd-missing00001","title":"Severity key is absent","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$missing_key" 2>"$TMPDIR/missing-key.err"
status=$?
missing_key_err="$(cat "$TMPDIR/missing-key.err")"
assert_failure "missing required key returns non-zero" "$status"
assert_contains "missing-key error says 'missing'" "missing" "$missing_key_err"
assert_contains "missing-key error reports line 1" "line 1" "$missing_key_err"

# Case 9: id present but an EMPTY string -> non-zero (id must be a non-empty
# string). Presence alone is not enough.
empty_id="$TMPDIR/empty-id.jsonl"
cat > "$empty_id" <<'EOF'
{"id":"","title":"Empty id string","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$empty_id" 2>"$TMPDIR/empty-id.err"
status=$?
empty_id_err="$(cat "$TMPDIR/empty-id.err")"
assert_failure "empty id string returns non-zero" "$status"
assert_contains "empty-id error mentions id" "id" "$empty_id_err"

# Case 10: invalid severity (not in critical/high/medium/low) -> non-zero.
invalid_sev="$TMPDIR/invalid-sev.jsonl"
cat > "$invalid_sev" <<'EOF'
{"id":"fnd-sev00000001","title":"Severity out of the enum","severity":"urgent","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$invalid_sev" 2>"$TMPDIR/invalid-sev.err"
status=$?
invalid_sev_err="$(cat "$TMPDIR/invalid-sev.err")"
assert_failure "invalid severity returns non-zero" "$status"
assert_contains "invalid-severity error mentions severity" "severity" "$invalid_sev_err"

# Case 11: invalid status (not in new/duplicate/needs-validation/
# likely-false-positive) -> non-zero.
invalid_status="$TMPDIR/invalid-status.jsonl"
cat > "$invalid_status" <<'EOF'
{"id":"fnd-status000001","title":"Status out of the enum","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"bogus","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$invalid_status" 2>"$TMPDIR/invalid-status.err"
status=$?
invalid_status_err="$(cat "$TMPDIR/invalid-status.err")"
assert_failure "invalid status returns non-zero" "$status"
assert_contains "invalid-status error mentions status" "status" "$invalid_status_err"

# Case 12: a NON-NULL type outside the enum -> non-zero (only a present, non-null,
# non-empty, out-of-enum value is rejected; null/empty are accepted — Cases 3).
invalid_type="$TMPDIR/invalid-type.jsonl"
cat > "$invalid_type" <<'EOF'
{"id":"fnd-type00000099","title":"Type is a non-null bogus value","severity":"high","type":"flavor","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$invalid_type" 2>"$TMPDIR/invalid-type.err"
status=$?
invalid_type_err="$(cat "$TMPDIR/invalid-type.err")"
assert_failure "non-null type outside enum returns non-zero" "$status"
assert_contains "invalid-type error mentions type" "type" "$invalid_type_err"

# Case 13: validation present but NOT an object (a string) -> non-zero. The
# internals are not validated, but the slot must be an object.
validation_scalar="$TMPDIR/validation-scalar.jsonl"
cat > "$validation_scalar" <<'EOF'
{"id":"fnd-val000000099","title":"Validation slot is a string not an object","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":"not-an-object"}
EOF
validate_findings_jsonl "$validation_scalar" 2>"$TMPDIR/validation-scalar.err"
status=$?
validation_scalar_err="$(cat "$TMPDIR/validation-scalar.err")"
assert_failure "non-object validation returns non-zero" "$status"
assert_contains "non-object validation error mentions validation" "validation" "$validation_scalar_err"

echo ""
echo "=== validate_findings_jsonl: line-number attribution ==="

# Case 14: in a 3-line file where ONLY the 2nd line is bad (invalid status), the
# validator must name line 2 — and must NOT misattribute to line 1 or line 3.
# This is the highest-value test: it proves the per-line counter is correct and
# that one bad line does not abort the others (lines 1 and 3 are valid).
mixed="$TMPDIR/mixed.jsonl"
cat > "$mixed" <<'EOF'
{"id":"fnd-line00000001","title":"First line is fine","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-line00000002","title":"Second line has a bad status","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"definitely-not-a-status","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-line00000003","title":"Third line is fine","severity":"low","type":"reliability","domain":"docs","lens":"readme-quality","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$mixed" 2>"$TMPDIR/mixed.err"
status=$?
mixed_err="$(cat "$TMPDIR/mixed.err")"
assert_failure "file with a bad 2nd line returns non-zero" "$status"
assert_contains "violation is attributed to line 2" "line 2" "$mixed_err"
assert_not_contains "valid line 1 is not flagged" "line 1" "$mixed_err"
assert_not_contains "valid line 3 is not flagged" "line 3" "$mixed_err"

echo ""
echo "=== validate_findings_jsonl: argument / file guards ==="

# Case 15: a missing file path -> non-zero (mirrors validate_manifest's
# missing-path guard).
validate_findings_jsonl "$TMPDIR/does-not-exist.jsonl" 2>/dev/null
status=$?
assert_failure "missing findings.jsonl returns non-zero" "$status"

echo ""
echo "=== validate_findings_jsonl: round-trips a real builder's output ==="

# Case 16: the live output of build_findings_jsonl_from_manifest must validate.
# This guards against future schema drift between the builder and the validator —
# the validator is only useful if it accepts what the builders actually emit.
# Pure: a tiny in-memory manifest, no AI model. (Skipped gracefully if the
# builder is somehow unavailable, so this never blocks the red phase.)
if declare -F build_findings_jsonl_from_manifest >/dev/null 2>&1; then
  rt_manifest="$TMPDIR/rt-manifest.json"
  cat > "$rt_manifest" <<'EOF'
[
  {
    "cluster_id": "missing-validation::lib-upload",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "High",
    "domain": "code",
    "lens": "input-validation",
    "verification_status": "verified",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"]
  }
]
EOF
  rt_jsonl="$TMPDIR/rt-findings.jsonl"
  build_findings_jsonl_from_manifest "$rt_manifest" "$rt_jsonl" 2>/dev/null
  validate_findings_jsonl "$rt_jsonl" 2>"$TMPDIR/rt.err"
  status=$?
  assert_success "build_findings_jsonl_from_manifest output validates clean" "$status"
else
  echo "  SKIP: build_findings_jsonl_from_manifest not available for round-trip"
fi

echo ""
echo "=== validate_findings_jsonl: missing-argument guard (distinct from missing file) ==="

# Case 17: called with NO argument at all -> non-zero, via the dedicated
# "$findings is empty" branch (return 2). Case 15 covers a path to a file that
# does not exist; this covers the structurally different no-arg branch, which
# emits its OWN message ("missing findings.jsonl path") — proving the two guards
# are not conflated.
validate_findings_jsonl 2>"$TMPDIR/no-arg.err"
status=$?
no_arg_err="$(cat "$TMPDIR/no-arg.err")"
assert_failure "no argument returns non-zero" "$status"
assert_contains "no-arg error mentions the missing path argument" "missing findings.jsonl path" "$no_arg_err"

# Case 18 (strengthens Case 15): a path to a non-existent file uses the OTHER
# guard and reports "not found" with the offending path — distinct stderr from
# the no-arg branch above. This pins which guard fired.
validate_findings_jsonl "$TMPDIR/definitely-absent.jsonl" 2>"$TMPDIR/absent.err"
status=$?
absent_err="$(cat "$TMPDIR/absent.err")"
assert_failure "non-existent file path returns non-zero" "$status"
assert_contains "missing-file error says 'not found'" "not found" "$absent_err"
assert_contains "missing-file error echoes the offending path" "definitely-absent.jsonl" "$absent_err"

echo ""
echo "=== validate_findings_jsonl: type empty-string accepted (distinct from null) ==="

# Case 19: type is the EMPTY STRING "" -> accepted. The enum guard short-circuits
# on `type != null and type != ""`, so "" must pass exactly like null (Case 3).
# A builder that emits "" instead of null must not be falsely rejected.
type_empty="$TMPDIR/type-empty.jsonl"
cat > "$type_empty" <<'EOF'
{"id":"fnd-typeempty001","title":"Type is the empty string","severity":"high","type":"","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$type_empty" 2>"$TMPDIR/type-empty.err"
status=$?
type_empty_err="$(cat "$TMPDIR/type-empty.err")"
assert_success "record with type:\"\" returns 0" "$status"
assert_not_contains "empty-string type is not flagged" "type" "$type_empty_err"

echo ""
echo "=== validate_findings_jsonl: every bad line is reported (accumulation) ==="

# Case 20: a 3-line file whose 1st AND 3rd lines are bad (line 2 is valid). Both
# bad lines must be reported — proving the validator does NOT stop at the first
# violation and that a good interior line is not flagged. Complements Case 14,
# which only had a single bad line.
two_bad="$TMPDIR/two-bad.jsonl"
cat > "$two_bad" <<'EOF'
{"id":"fnd-twobad00001","title":"First line has a bad severity","severity":"urgent","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-twobad00002","title":"Second line is fine","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
{"id":"fnd-twobad00003","title":"Third line has a bad status","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"bogus","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$two_bad" 2>"$TMPDIR/two-bad.err"
status=$?
two_bad_err="$(cat "$TMPDIR/two-bad.err")"
assert_failure "file with two bad lines returns non-zero" "$status"
assert_contains "first bad line (1) is reported" "line 1" "$two_bad_err"
assert_contains "third bad line (3) is reported" "line 3" "$two_bad_err"
assert_not_contains "valid middle line 2 is not flagged" "line 2" "$two_bad_err"

# Case 21: a SINGLE line carrying TWO independent violations (bad severity AND bad
# status) -> both are reported for that one line. Proves the jq filter emits every
# violation per line (not just the first) and the inner loop counts each.
multi_violation="$TMPDIR/multi-violation.jsonl"
cat > "$multi_violation" <<'EOF'
{"id":"fnd-multiviol01","title":"One line, two problems","severity":"urgent","type":"security","domain":"code","lens":"input-validation","status":"bogus","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$multi_violation" 2>"$TMPDIR/multi-violation.err"
status=$?
multi_violation_err="$(cat "$TMPDIR/multi-violation.err")"
assert_failure "line with two violations returns non-zero" "$status"
assert_contains "both-violations: severity is reported" "severity" "$multi_violation_err"
assert_contains "both-violations: status is reported" "status" "$multi_violation_err"

echo ""
echo "=== validate_findings_jsonl: blank-line handling + line numbering across blanks ==="

# Case 22: a blank line BETWEEN two valid records must be skipped, not flagged as
# "not a JSON object" — a clean file with an interior blank still returns 0.
blank_clean="$TMPDIR/blank-clean.jsonl"
cat > "$blank_clean" <<'EOF'
{"id":"fnd-blankok0001","title":"Before the blank","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}

{"id":"fnd-blankok0002","title":"After the blank","severity":"low","type":"reliability","domain":"docs","lens":"readme-quality","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$blank_clean" 2>"$TMPDIR/blank-clean.err"
status=$?
blank_clean_err="$(cat "$TMPDIR/blank-clean.err")"
assert_success "interior blank line between valid records returns 0" "$status"
assert_not_contains "blank line is not flagged as an object error" "object" "$blank_clean_err"

# Case 23: line 1 valid, line 2 BLANK, line 3 bad (invalid status). The violation
# must be attributed to line 3 — NOT line 2 — proving lineno is incremented for
# the blank line before it is skipped, so reported numbers match the editor view.
blank_count="$TMPDIR/blank-count.jsonl"
cat > "$blank_count" <<'EOF'
{"id":"fnd-blankcnt001","title":"Line one is valid","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}

{"id":"fnd-blankcnt003","title":"Line three has a bad status","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"nope","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$blank_count" 2>"$TMPDIR/blank-count.err"
status=$?
blank_count_err="$(cat "$TMPDIR/blank-count.err")"
assert_failure "bad line after a blank returns non-zero" "$status"
assert_contains "violation is attributed to line 3 (blank line counted)" "line 3" "$blank_count_err"
assert_not_contains "blank line 2 is not flagged" "line 2" "$blank_count_err"

echo ""
echo "=== validate_findings_jsonl: final line with no trailing newline ==="

# Case 24: a single valid record written WITHOUT a trailing newline must still be
# read and validated (the `read ... || [[ -n \"\$line\" ]]` idiom). printf %s emits
# no terminating newline, unlike the heredocs above.
no_nl_ok="$TMPDIR/no-newline-ok.jsonl"
printf '%s' '{"id":"fnd-nonl000001","title":"No trailing newline, valid","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}' > "$no_nl_ok"
validate_findings_jsonl "$no_nl_ok" 2>"$TMPDIR/no-newline-ok.err"
status=$?
assert_success "valid final line without trailing newline returns 0" "$status"

# Case 25: a BAD record with no trailing newline must still be caught and reported
# with the correct line number — confirming the no-newline final line is not
# silently dropped.
no_nl_bad="$TMPDIR/no-newline-bad.jsonl"
printf '%s' '{"id":"fnd-nonl000099","title":"No trailing newline, bad status","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"bogus","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}' > "$no_nl_bad"
validate_findings_jsonl "$no_nl_bad" 2>"$TMPDIR/no-newline-bad.err"
status=$?
no_nl_bad_err="$(cat "$TMPDIR/no-newline-bad.err")"
assert_failure "bad final line without trailing newline returns non-zero" "$status"
assert_contains "no-newline bad line reports line 1" "line 1" "$no_nl_bad_err"
assert_contains "no-newline bad line mentions status" "status" "$no_nl_bad_err"

echo ""
echo "=== validate_findings_jsonl: id present-but-null (distinct from empty string / missing) ==="

# Case 26: id is present but its value is null. has("id") is true (the key
# exists), so this is NOT a "missing required key" violation (Case 8) — it must
# instead fail the non-empty-string check, exactly like the empty-string id of
# Case 9 but via the null value path. A builder bug that emits "id":null (rather
# than dropping the key) must still be rejected, not silently accepted.
id_null="$TMPDIR/id-null.jsonl"
cat > "$id_null" <<'EOF'
{"id":null,"title":"id is present but null","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$id_null" 2>"$TMPDIR/id-null.err"
status=$?
id_null_err="$(cat "$TMPDIR/id-null.err")"
assert_failure "id:null returns non-zero" "$status"
assert_contains "id:null error mentions id" "id" "$id_null_err"
assert_not_contains "id:null is not misreported as a missing key" "missing required key: id" "$id_null_err"

echo ""
echo "=== validate_findings_jsonl: missing enum key emits ONLY 'missing' (has() guard discipline) ==="

# Case 27: a record MISSING severity must report "missing required key: severity"
# and must NOT ALSO emit "invalid severity" — the enum check is guarded by
# has("severity"). Without that guard, jq would evaluate (severities|index(null))
# == null on the absent key and emit a spurious second violation. Case 8 only
# asserts the "missing" message is present; it never asserts the enum message is
# ABSENT, so a regression removing the has() guard would pass Case 8 but fail
# here. This pins the guard discipline the implementation calls "load-bearing".
guard_sev="$TMPDIR/guard-severity.jsonl"
cat > "$guard_sev" <<'EOF'
{"id":"fnd-guardsev001","title":"Severity key absent — only one violation expected","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":{}}
EOF
validate_findings_jsonl "$guard_sev" 2>"$TMPDIR/guard-severity.err"
status=$?
guard_sev_err="$(cat "$TMPDIR/guard-severity.err")"
assert_failure "missing severity returns non-zero" "$status"
assert_contains "missing severity reports the missing key" "missing required key: severity" "$guard_sev_err"
assert_not_contains "missing severity does NOT also emit a spurious enum violation" "invalid severity" "$guard_sev_err"

# Case 28: same guard discipline on the OBJECT arm. A record MISSING validation
# must report "missing required key: validation" and must NOT also emit
# "validation must be an object" — the object-shape check is guarded by
# has("validation"). This covers the guard arm whose shape differs from the enum
# checks of Case 27 (type-check vs index-lookup), so both guard families are
# pinned against a regression.
guard_val="$TMPDIR/guard-validation.jsonl"
cat > "$guard_val" <<'EOF'
{"id":"fnd-guardval001","title":"Validation key absent — only one violation expected","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null}
EOF
validate_findings_jsonl "$guard_val" 2>"$TMPDIR/guard-validation.err"
status=$?
guard_val_err="$(cat "$TMPDIR/guard-validation.err")"
assert_failure "missing validation returns non-zero" "$status"
assert_contains "missing validation reports the missing key" "missing required key: validation" "$guard_val_err"
assert_not_contains "missing validation does NOT also emit a spurious object violation" "must be an object" "$guard_val_err"

echo ""
echo "=== validate_findings_jsonl: validation present-but-null (distinct from string Case 13) ==="

# Case 29: validation is present but its value is null. has("validation") is true,
# so this is NOT a missing-key violation — it must fail the object-shape check
# (null type != "object"), exactly like the string value of Case 13 but via the
# null path. The slot must be an OBJECT; a builder that emits "validation":null
# instead of {} must be rejected.
validation_null="$TMPDIR/validation-null.jsonl"
cat > "$validation_null" <<'EOF'
{"id":"fnd-valnull0001","title":"Validation slot is null not an object","severity":"high","type":"security","domain":"code","lens":"input-validation","status":"new","primary_location":"","confidence":null,"duplicate_group":null,"markdown_path":null,"validation":null}
EOF
validate_findings_jsonl "$validation_null" 2>"$TMPDIR/validation-null.err"
status=$?
validation_null_err="$(cat "$TMPDIR/validation-null.err")"
assert_failure "validation:null returns non-zero" "$status"
assert_contains "validation:null error mentions validation" "validation" "$validation_null_err"
assert_not_contains "validation:null is not misreported as a missing key" "missing required key: validation" "$validation_null_err"

finish
