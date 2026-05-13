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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  (( FAIL == 0 )) || exit 1
}

TMPDIR="$(mktemp -d "$SCRIPT_DIR/logs/test-min-severity-cross-link.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
manifest="$TMPDIR/manifest.json"
verification="$TMPDIR/verification.json"
export CROSS_LINK_MODE=comment

cat > "$manifest" <<'JSON'
[
  {
    "cluster_id": "low::verified-comment",
    "title": "[low] Existing issue has fresh evidence",
    "severity": "low",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [
      {
        "type": "comment",
        "issue_number": 42,
        "body": "Fresh below-threshold evidence still belongs on the existing issue."
      }
    ],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "low::wrong-comment",
    "title": "[low] Wrong-source issue has fresh evidence",
    "severity": "low",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run/rounds/round-1/lens-outputs/code/wrong.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [
      {
        "type": "comment",
        "issue_number": 99,
        "body": "This WRONG-source comment must not survive through the sidecar."
      }
    ],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "high::create",
    "title": "[high] High issue remains createable",
    "severity": "high",
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

cat > "$verification" <<'JSON'
[
  {
    "source_finding_path": "logs/run/rounds/round-1/lens-outputs/code/input-validation.md",
    "status": "RIGHT"
  },
  {
    "source_finding_path": "logs/run/rounds/round-1/lens-outputs/code/wrong.md",
    "status": "WRONG"
  },
  {
    "source_finding_path": "logs/run/rounds/round-1/lens-outputs/security/injection.md",
    "status": "RIGHT"
  }
]
JSON

validate_manifest "$manifest" 2>"$TMPDIR/manifest.err"
assert_success "cross-link manifest validates before filtering" "$?"
_synthesize_filter_manifest_min_severity "$manifest" high "$verification"
assert_success "cross-link filter returns success" "$?"

sidecar="$TMPDIR/cross-link-actions.preserved.json"
assert_eq "below-threshold create entries are removed" "high::create" "$(jq -r '.[].cluster_id' "$manifest")"
assert_eq "only verified comment action is preserved" "1" "$(jq 'length' "$sidecar")"
assert_eq "preserved comment keeps issue number" "42" "$(jq -r '.[0].issue_number' "$sidecar")"
assert_eq "WRONG-source comment is not preserved" "false" "$(jq 'any(.issue_number == 99)' "$sidecar")"

finish
