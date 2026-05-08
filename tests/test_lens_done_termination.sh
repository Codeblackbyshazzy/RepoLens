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

# Regression test for issue #125: compliance, IaC, and Android lenses that
# mention DONE locally must also make happy-path DONE explicit at body end.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    fail_with "$desc" "Unexpected: $needle"
  else
    pass_with "$desc"
  fi
}

echo "=== Test Suite: lens DONE termination (issue #125) ==="

EXPECTED_SENTENCE="After you have created all real GitHub issues for your confirmed findings (or if there are no findings to report), output **DONE** as the very first word of your response AND **DONE** as the very last word."

TARGET_FILES=()
while IFS= read -r rel_path; do
  TARGET_FILES+=("$rel_path")
done < <(cd "$SCRIPT_DIR" && find prompts/lenses/compliance -maxdepth 1 -type f -name '*.md' | sort)

while IFS= read -r rel_path; do
  TARGET_FILES+=("$rel_path")
done < <(cd "$SCRIPT_DIR" && find prompts/lenses/iac -maxdepth 1 -type f -name '*.md' | sort)

TARGET_FILES+=(
  "prompts/lenses/android/detection-bypass.md"
  "prompts/lenses/android/drozer-attack-surface.md"
  "prompts/lenses/android/frida-runtime.md"
  "prompts/lenses/android/gradle-static-analysis.md"
  "prompts/lenses/android/intent-fuzzing.md"
  "prompts/lenses/android/keystore-extraction.md"
  "prompts/lenses/android/logcat-leaks.md"
  "prompts/lenses/android/ssl-pinning-mitm.md"
)

echo ""
echo "Test 1: expected affected lens inventory is present"
assert_eq "target lens count" "69" "${#TARGET_FILES[@]}"
for rel_path in "${TARGET_FILES[@]}"; do
  TOTAL=$((TOTAL + 1))
  if [[ -f "$SCRIPT_DIR/$rel_path" ]]; then
    pass_with "$rel_path exists"
  else
    fail_with "$rel_path exists" "Missing target file"
  fi
done

echo ""
echo "Test 2: each affected lens ends with the standardized Termination block"
for rel_path in "${TARGET_FILES[@]}"; do
  file="$SCRIPT_DIR/$rel_path"
  heading="$(awk 'NF { prev=last; last=$0 } END { print prev }' "$file")"
  sentence="$(awk 'NF { last=$0 } END { print last }' "$file")"
  assert_eq "$rel_path final heading" "### Termination" "$heading"
  assert_eq "$rel_path final sentence" "$EXPECTED_SENTENCE" "$sentence"
done

echo ""
echo "Test 3: each affected lens has exactly one standardized happy-path instruction"
for rel_path in "${TARGET_FILES[@]}"; do
  file="$SCRIPT_DIR/$rel_path"
  count="$(grep -cF "$EXPECTED_SENTENCE" "$file")"
  assert_eq "$rel_path standardized instruction count" "1" "$count"
done

echo ""
echo "Test 4: every lens with in-body DONE has a body-level happy-path termination"
while IFS= read -r rel_path; do
  file="$SCRIPT_DIR/$rel_path"
  heading="$(awk 'NF { prev=last; last=$0 } END { print prev }' "$file")"
  sentence="$(awk 'NF { last=$0 } END { print last }' "$file")"
  assert_eq "$rel_path DONE-bearing final heading" "### Termination" "$heading"
  assert_eq "$rel_path DONE-bearing final sentence" "$EXPECTED_SENTENCE" "$sentence"
done < <(cd "$SCRIPT_DIR" && grep -R -l 'DONE' prompts/lenses --include='*.md' | sort)

echo ""
echo "Test 5: sampled clean lenses remain free of body-local DONE duplication"
CLEAN_SAMPLES=(
  "prompts/lenses/architecture/coupling.md"
  "prompts/lenses/security/injection.md"
  "prompts/lenses/performance/caching.md"
)
for rel_path in "${CLEAN_SAMPLES[@]}"; do
  assert_not_contains "$rel_path has no body-local standardized instruction" "$EXPECTED_SENTENCE" "$SCRIPT_DIR/$rel_path"
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
