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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/synthesize.sh"

PASS=0
FAIL=0
TOTAL=0

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then pass_with "$desc"; else fail_with "$desc" "Expected '$expected', got '$actual'"; fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected exit 0, got $actual"; fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then pass_with "$desc"; else fail_with "$desc" "Expected non-zero exit"; fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  (( FAIL == 0 )) || exit 1
}

TMPDIR="$(mktemp -d "$SCRIPT_DIR/logs/test-min-severity-filtering.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== shared severity threshold predicate ==="

for severity in low medium high critical; do
  severity_meets_min "$severity" low
  assert_success "$severity meets low" "$?"
done

severity_meets_min low medium
assert_failure "low does not meet medium" "$?"
severity_meets_min medium high
assert_failure "medium does not meet high" "$?"
severity_meets_min high high
assert_success "high meets high inclusively" "$?"
severity_meets_min critical high
assert_success "critical meets high" "$?"
severity_meets_min "[HIGH]" medium
assert_success "bracketed uppercase severity is normalized before comparison" "$?"
severity_meets_min high urgent
assert_failure "invalid minimum threshold is rejected" "$?"

echo ""
echo "=== manifest filtering ==="

manifest="$TMPDIR/manifest.json"
cat > "$manifest" <<'JSON'
[
  {
    "cluster_id": "low::one",
    "title": "[low] Low polish finding",
    "severity": "low",
    "domain": "docs",
    "lens": "readme-quality",
    "root_cause_category": "docs-drift",
    "source_finding_paths": ["logs/run/rounds/round-1/lens-outputs/docs/readme-quality.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["docs"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "medium::one",
    "title": "[medium] Medium bug",
    "severity": "medium",
    "domain": "code",
    "lens": "dead-code",
    "root_cause_category": "maintainability",
    "source_finding_paths": ["logs/run/rounds/round-1/lens-outputs/code-quality/dead-code.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "high::one",
    "title": "[high] High bug",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "critical::one",
    "title": "[critical] Critical bug",
    "severity": "critical",
    "domain": "security",
    "lens": "injection",
    "root_cause_category": "injection",
    "source_finding_paths": ["logs/run/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["security"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  }
]
JSON

validate_manifest "$manifest" 2>"$TMPDIR/manifest.err"
assert_success "mixed manifest validates before filtering" "$?"
_synthesize_filter_manifest_min_severity "$manifest" high
assert_success "manifest filter returns success" "$?"
assert_eq "high threshold keeps high and critical only" "high,critical" "$(jq -r 'map(.severity) | join(",")' "$manifest")"
validate_manifest "$manifest" 2>"$TMPDIR/filtered.err"
assert_success "filtered manifest remains valid" "$?"

finish
