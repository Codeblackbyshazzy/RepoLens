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

set -uo pipefail

# Tests for issue #320: closed finding-type taxonomy in config/finding-types.json.
# Pure jq/bash — NEVER invoke a real model.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TYPES_FILE="$SCRIPT_DIR/config/finding-types.json"

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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== finding-types taxonomy config ==="

# Acceptance: config/finding-types.json exists.
if [[ ! -f "$TYPES_FILE" ]]; then
  fail_with "config/finding-types.json exists" "Missing $TYPES_FILE"
  finish
fi

# Acceptance: valid JSON (jq . config/finding-types.json succeeds).
jq empty "$TYPES_FILE" >/dev/null 2>&1
rc=$?
assert_eq "config/finding-types.json is valid JSON" "0" "$rc"

# House style: single top-level object with a "types" array (mirrors config/domains.json).
assert_eq "top-level .types is an array" \
  "array" "$(jq -r '.types | type' "$TYPES_FILE" 2>/dev/null)"

# Acceptance: contains exactly the six type ids, no more, no fewer.
assert_eq "exactly six types" \
  "6" "$(jq '.types | length' "$TYPES_FILE" 2>/dev/null)"

# Acceptance: the id set is precisely the six closed (suffixed) taxonomy ids.
# Comparing the sorted full set catches both extras and omissions at once.
expected_ids="external-dependency maintainability performance-risk reliability-bug security-vulnerability test-gap"
actual_ids="$(jq -r '.types[].id' "$TYPES_FILE" 2>/dev/null | sort | paste -sd' ' -)"
assert_eq "id set matches the six closed taxonomy ids" "$expected_ids" "$actual_ids"

# Acceptance: each entry has id, name, and description (all present and non-empty).
assert_eq "every entry has non-empty id, name, and description" \
  "6" "$(jq '[.types[] | select((.id | length > 0) and (.name | length > 0) and (.description | length > 0))] | length' "$TYPES_FILE" 2>/dev/null)"

# Integrity: no duplicate ids (unique id count equals the six entries).
assert_eq "no duplicate ids" \
  "6" "$(jq -r '.types[].id' "$TYPES_FILE" 2>/dev/null | sort -u | wc -l | tr -d ' ')"

# Acceptance: external-dependency description notes the "needs scanner validation" pairing.
ext_desc="$(jq -r '.types[] | select(.id == "external-dependency") | .description' "$TYPES_FILE" 2>/dev/null)"
if printf '%s' "$ext_desc" | grep -qi 'scanner'; then
  ext_mention="yes"
else
  ext_mention="no"
fi
assert_eq "external-dependency description notes scanner validation" "yes" "$ext_mention"

# Acceptance (tighter): the description references the "scanner validation" classification
# specifically — not merely the word "scanner" — matching the issue's exact wording
# ("needs scanner validation").
if printf '%s' "$ext_desc" | grep -qi 'scanner validation'; then
  ext_classification="yes"
else
  ext_classification="no"
fi
assert_eq "external-dependency description references the 'scanner validation' classification" \
  "yes" "$ext_classification"

# Issue mandates exact human labels per id (not just non-empty names). Pin the full
# id=>name mapping so a mislabel (or a regression to the schema doc's short ids, e.g.
# 'security' instead of 'security-vulnerability') is caught. Comparing the sorted set
# flags any wrong/missing label in one assertion.
expected_pairs="external-dependency=External Dependency
maintainability=Maintainability
performance-risk=Performance Risk
reliability-bug=Reliability Bug
security-vulnerability=Security Vulnerability
test-gap=Test Gap"
actual_pairs="$(jq -r '.types[] | "\(.id)=\(.name)"' "$TYPES_FILE" 2>/dev/null | sort | paste -sd$'\n' -)"
assert_eq "each id maps to its exact human label" "$expected_pairs" "$actual_pairs"

# Integrity: every entry's name is distinct from its machine id (the human label must be
# a real label, not a copy of the id). Counts entries where name != id; expects all six.
assert_eq "every name differs from its id" \
  "6" "$(jq '[.types[] | select(.name != .id)] | length' "$TYPES_FILE" 2>/dev/null)"

# Integrity: all six descriptions are distinct (guards against copy-pasted or placeholder
# descriptions slipping in), mirroring the no-duplicate-ids check above.
assert_eq "all six descriptions are distinct" \
  "6" "$(jq -r '.types[].description' "$TYPES_FILE" 2>/dev/null | sort -u | wc -l | tr -d ' ')"

finish
