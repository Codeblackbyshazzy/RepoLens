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

# Regression test for issue #229: 28 lenses across 6 domains
# (kubernetes, llm-security, visual-design, design-system, frontend, i18n)
# must include an applicability-DONE early-exit sentence in
# `## Your Expert Focus` and end with the canonical `### Termination`
# block. Together these let the agent short-circuit on iteration 1 when
# the repo doesn't match the lens's domain instead of burning
# MAX_ITERATIONS_PER_LENS (default 20) per inapplicable run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

EXPECTED_SENTENCE="After you have created all real GitHub issues for your confirmed findings (or if there are no findings to report), output **DONE** as the very first word of your response AND **DONE** as the very last word."

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

echo "=== Test Suite: lens applicability parity (issue #229) ==="

TARGET_FILES=(
  "prompts/lenses/kubernetes/image-security.md"
  "prompts/lenses/kubernetes/ingress-tls.md"
  "prompts/lenses/kubernetes/network-policies.md"
  "prompts/lenses/kubernetes/rbac.md"
  "prompts/lenses/kubernetes/resource-management.md"
  "prompts/lenses/kubernetes/secrets-management.md"
  "prompts/lenses/kubernetes/security-context.md"
  "prompts/lenses/llm-security/agent-isolation.md"
  "prompts/lenses/llm-security/cost-control.md"
  "prompts/lenses/llm-security/credential-exposure.md"
  "prompts/lenses/llm-security/output-sanitization.md"
  "prompts/lenses/llm-security/prompt-injection.md"
  "prompts/lenses/visual-design/color-system.md"
  "prompts/lenses/visual-design/icon-consistency.md"
  "prompts/lenses/visual-design/spacing-system.md"
  "prompts/lenses/visual-design/typography-scale.md"
  "prompts/lenses/visual-design/visual-hierarchy.md"
  "prompts/lenses/design-system/component-library-usage.md"
  "prompts/lenses/design-system/css-architecture.md"
  "prompts/lenses/design-system/design-tokens.md"
  "prompts/lenses/design-system/ui-copy-consistency.md"
  "prompts/lenses/frontend/accessibility.md"
  "prompts/lenses/frontend/component-architecture.md"
  "prompts/lenses/frontend/frontend-security.md"
  "prompts/lenses/frontend/responsive-design.md"
  "prompts/lenses/frontend/routing.md"
  "prompts/lenses/i18n/i18n-formatting.md"
  "prompts/lenses/i18n/i18n-strings.md"
)

# Each entry maps a target lens to a domain-specific signal token that the
# applicability sentence MUST mention. Catches lazy copy-paste between
# domains (e.g., kubernetes wording dropped into a frontend lens).
declare -A DOMAIN_SIGNAL=(
  ["prompts/lenses/kubernetes/image-security.md"]="Kubernetes"
  ["prompts/lenses/kubernetes/ingress-tls.md"]="Kubernetes"
  ["prompts/lenses/kubernetes/network-policies.md"]="Kubernetes"
  ["prompts/lenses/kubernetes/rbac.md"]="Kubernetes"
  ["prompts/lenses/kubernetes/resource-management.md"]="Kubernetes"
  ["prompts/lenses/kubernetes/secrets-management.md"]="Kubernetes"
  ["prompts/lenses/kubernetes/security-context.md"]="Kubernetes"
  ["prompts/lenses/llm-security/agent-isolation.md"]="anthropic"
  ["prompts/lenses/llm-security/cost-control.md"]="anthropic"
  ["prompts/lenses/llm-security/credential-exposure.md"]="anthropic"
  ["prompts/lenses/llm-security/output-sanitization.md"]="anthropic"
  ["prompts/lenses/llm-security/prompt-injection.md"]="anthropic"
  ["prompts/lenses/visual-design/color-system.md"]="stylesheet"
  ["prompts/lenses/visual-design/icon-consistency.md"]="stylesheet"
  ["prompts/lenses/visual-design/spacing-system.md"]="stylesheet"
  ["prompts/lenses/visual-design/typography-scale.md"]="stylesheet"
  ["prompts/lenses/visual-design/visual-hierarchy.md"]="stylesheet"
  ["prompts/lenses/design-system/component-library-usage.md"]="stylesheet"
  ["prompts/lenses/design-system/css-architecture.md"]="stylesheet"
  ["prompts/lenses/design-system/design-tokens.md"]="stylesheet"
  ["prompts/lenses/design-system/ui-copy-consistency.md"]="user-facing"
  ["prompts/lenses/frontend/accessibility.md"]="React"
  ["prompts/lenses/frontend/component-architecture.md"]="React"
  ["prompts/lenses/frontend/frontend-security.md"]="React"
  ["prompts/lenses/frontend/responsive-design.md"]="React"
  ["prompts/lenses/frontend/routing.md"]="React"
  ["prompts/lenses/i18n/i18n-formatting.md"]="i18next"
  ["prompts/lenses/i18n/i18n-strings.md"]="i18next"
)

echo ""
echo "Test 1: expected target lens inventory is present"
assert_eq "target lens count" "28" "${#TARGET_FILES[@]}"
for rel_path in "${TARGET_FILES[@]}"; do
  TOTAL=$((TOTAL + 1))
  if [[ -f "$SCRIPT_DIR/$rel_path" ]]; then
    pass_with "$rel_path exists"
  else
    fail_with "$rel_path exists" "Missing target file"
  fi
done

echo ""
echo "Test 2: each target lens has an applicability sentence with DONE before '### How You Investigate'"
for rel_path in "${TARGET_FILES[@]}"; do
  file="$SCRIPT_DIR/$rel_path"
  TOTAL=$((TOTAL + 1))
  # Extract everything from "## Your Expert Focus" up to (but not including)
  # the "### How You Investigate" heading. The applicability sentence with a
  # DONE token must live in this prelude — that is what allows the agent to
  # short-circuit on iteration 1.
  prelude="$(awk '
    /^## Your Expert Focus[[:space:]]*$/ { in_section = 1; next }
    /^### How You Investigate[[:space:]]*$/ { in_section = 0 }
    in_section { print }
  ' "$file")"
  if printf '%s\n' "$prelude" | grep -qE 'output (\*\*DONE\*\*|DONE)'; then
    pass_with "$rel_path applicability DONE in Your Expert Focus prelude"
  else
    fail_with "$rel_path applicability DONE in Your Expert Focus prelude" \
      "No 'output DONE' or 'output **DONE**' sentence found before '### How You Investigate'"
  fi
done

echo ""
echo "Test 3: each target lens ends with the standardized Termination block"
for rel_path in "${TARGET_FILES[@]}"; do
  file="$SCRIPT_DIR/$rel_path"
  heading="$(awk 'NF { prev=last; last=$0 } END { print prev }' "$file")"
  sentence="$(awk 'NF { last=$0 } END { print last }' "$file")"
  assert_eq "$rel_path final heading" "### Termination" "$heading"
  assert_eq "$rel_path final sentence" "$EXPECTED_SENTENCE" "$sentence"
done

echo ""
echo "Test 4: each applicability sentence names a domain-specific signal token"
for rel_path in "${TARGET_FILES[@]}"; do
  file="$SCRIPT_DIR/$rel_path"
  token="${DOMAIN_SIGNAL[$rel_path]}"
  TOTAL=$((TOTAL + 1))
  prelude="$(awk '
    /^## Your Expert Focus[[:space:]]*$/ { in_section = 1; next }
    /^### How You Investigate[[:space:]]*$/ { in_section = 0 }
    in_section { print }
  ' "$file")"
  if printf '%s\n' "$prelude" | grep -qF "$token"; then
    pass_with "$rel_path applicability mentions '$token'"
  else
    fail_with "$rel_path applicability mentions '$token'" \
      "Prelude does not contain expected domain signal '$token' — possible cross-domain copy-paste"
  fi
done

echo ""
echo "Test 5: standardized Termination instruction appears exactly once per target lens"
for rel_path in "${TARGET_FILES[@]}"; do
  file="$SCRIPT_DIR/$rel_path"
  count="$(grep -cF "$EXPECTED_SENTENCE" "$file")"
  assert_eq "$rel_path standardized instruction count" "1" "$count"
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
