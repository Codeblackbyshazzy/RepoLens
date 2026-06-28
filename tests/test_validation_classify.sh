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

# Integration fixture tests for issue #346 — end-to-end parse + classify.
#
# The validation slice spans a prompt contract (#317), authoring guidance
# (#323), a parser (#332), a classifier (#334), and an anchor validator (#345).
# Each ships its own unit suite. This suite is the INTEGRATION guard: it drives
# the real `lib/validation.sh` functions over static markdown fixtures and
# proves the full chain — finding markdown -> `parse_validation_block` ->
# `validation` JSON object -> `classify_validation_status` -> `status` string —
# yields the right verdict on three representative findings. The classifier
# calls `validate_proof_anchors` internally, so the anchor validator is
# exercised transitively without this suite calling it directly.
#
# No real AI models are invoked (CLAUDE.md::Tests): the lib is sourced and the
# pure functions are called directly, never via `repolens.sh`. The whole suite
# is pure bash + jq and runs in well under a second.
#
# Contract under test (issue #346 acceptance criteria):
#   - Three fixtures cover the local-validatable, needs-scanner, and no-anchor
#     cases.
#   - Each fixture parsed-then-classified maps to `new`, `needs-validation`,
#     and `likely-false-positive` respectively.
#   - The parsed `validation` object is FULLY POPULATED (all six fields
#     non-empty / non-empty array) for the local-validatable fixture.
#   - Every emitted status is one of the three legal values (never `duplicate`).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATION_LIB="$SCRIPT_DIR/lib/validation.sh"
FIXTURES="$SCRIPT_DIR/tests/fixtures/validation"
LOCAL_VALIDATABLE="$FIXTURES/local-validatable.md"
NEEDS_SCANNER="$FIXTURES/needs-scanner.md"
NO_ANCHOR="$FIXTURES/no-anchor.md"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

# Assert a jq filter is truthy (exit 0) against the given JSON.
assert_jq_true() {
  local desc="$1" json="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$json" | jq -e "$filter" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq filter not truthy: $filter"
  fi
}

# Assert a classify status is one of the three legal values — never `duplicate`
# (owned by the dedup slice) or anything outside the 3-set.
assert_member() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  case "$actual" in
    new | needs-validation | likely-false-positive)
      pass_with "$desc"
      ;;
    *)
      fail_with "$desc" "Got '$actual' — not a legal classify status (must never be 'duplicate' or anything outside the 3-set)"
      ;;
  esac
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

echo ""
echo "=== Test Suite: end-to-end parse+classify fixtures (issue #346) ==="
echo ""

# Red-phase guard: if the module does not exist yet, fail cleanly and stop so
# the runner reports a single discoverable failure rather than a cascade of
# "command not found" noise.
if [[ ! -f "$VALIDATION_LIB" ]]; then
  fail_with "lib/validation.sh exists" "Missing $VALIDATION_LIB (not yet implemented)"
  finish
fi

# Guard the fixtures too — a missing fixture would otherwise read as the
# all-empty object and silently classify `likely-false-positive`, masking a
# real wiring failure.
for fixture in "$LOCAL_VALIDATABLE" "$NEEDS_SCANNER" "$NO_ANCHOR"; do
  TOTAL=$((TOTAL + 1))
  if [[ -f "$fixture" ]]; then
    pass_with "fixture exists: ${fixture#"$SCRIPT_DIR/"}"
  else
    fail_with "fixture exists: ${fixture#"$SCRIPT_DIR/"}" "Missing $fixture"
  fi
done

echo ""
echo "--- Group 1: sourceable module with no side effects ---"
# Sourcing must define functions only — no output, no work at source time.
# shellcheck disable=SC1090
source_out="$(source "$VALIDATION_LIB" 2>&1)"
assert_eq "sourcing lib/validation.sh emits nothing" "" "$source_out"

# shellcheck disable=SC1090
source "$VALIDATION_LIB"
for fn in parse_validation_block classify_validation_status validate_proof_anchors; do
  TOTAL=$((TOTAL + 1))
  if declare -F "$fn" >/dev/null 2>&1; then
    pass_with "$fn is defined after sourcing"
  else
    fail_with "$fn is defined after sourcing"
    # Nothing else can be tested without the chain — stop here.
    finish
  fi
done

echo ""
echo "--- Group 2: end-to-end parse -> classify per fixture (AC #2) ---"
# Wiring the parser output straight into the classifier is what makes this an
# integration assertion rather than a re-run of the two unit suites.
classify_fixture() {
  classify_validation_status "$(parse_validation_block "$1")"
}

local_status="$(classify_fixture "$LOCAL_VALIDATABLE")"
assert_eq "local-validatable fixture -> new" "new" "$local_status"
assert_member "local-validatable status is a legal verdict" "$local_status"

scanner_status="$(classify_fixture "$NEEDS_SCANNER")"
assert_eq "needs-scanner fixture -> needs-validation" "needs-validation" "$scanner_status"
assert_member "needs-scanner status is a legal verdict" "$scanner_status"

no_anchor_status="$(classify_fixture "$NO_ANCHOR")"
assert_eq "no-anchor fixture -> likely-false-positive" "likely-false-positive" "$no_anchor_status"
assert_member "no-anchor status is a legal verdict" "$no_anchor_status"

echo ""
echo "--- Group 3: six-field round-trip for the local-validatable fixture (AC #3) ---"
local_json="$(parse_validation_block "$LOCAL_VALIDATABLE")"

assert_jq_true "parsed object is valid JSON" "$local_json" '.'
assert_eq "object has exactly the six contract keys (sorted)" \
  '["attacker_source","missing_guard","preconditions","proof_anchors","sink_effect","suggested_validation"]' \
  "$(printf '%s' "$local_json" | jq -c 'keys')"

# "Fully populated" means non-empty values, not merely present keys — the
# missing-block object also carries all six keys but with empty values.
assert_jq_true "all five string fields are non-empty" "$local_json" \
  '[.attacker_source,.missing_guard,.sink_effect,.preconditions,.suggested_validation] | all(. != "")'
assert_jq_true "proof_anchors is a non-empty array" "$local_json" \
  '(.proof_anchors | type == "array") and (.proof_anchors | length > 0)'

# Spot-check the values that drive the `new` verdict round-trip verbatim: a
# solid `path:line` anchor and a local `grep` command.
assert_eq "proof_anchors round-trips the path:line anchor" \
  '["app/download.py:88"]' \
  "$(printf '%s' "$local_json" | jq -c '.proof_anchors')"
assert_eq "suggested_validation round-trips the local command" \
  'grep -n "open(.*request" app/download.py' \
  "$(printf '%s' "$local_json" | jq -r '.suggested_validation')"

finish
