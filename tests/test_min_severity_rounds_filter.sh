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
source "$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; }

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then pass_with "$desc"; else fail_with "$desc" "Missing: $needle"; fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then pass_with "$desc"; else fail_with "$desc" "Unexpected: $needle"; fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  (( FAIL == 0 )) || exit 1
}

TMPDIR="$(mktemp -d "$SCRIPT_DIR/logs/test-min-severity-rounds.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
round_dir="$TMPDIR/rounds/round-1"
out_dir="$round_dir/lens-outputs/code-quality"
mkdir -p "$out_dir"

write_finding() {
  local path="$1" severity="$2" lens="$3" category="$4" suspect="$5"
  cat > "$path" <<EOF
---
severity: $severity
domain: code-quality
lens: $lens
root_cause_category: $category
suspect_files:
  - $suspect
---
# Finding
EOF
}

write_finding "$out_dir/001-low.md" low dead-code polish src/low.sh
write_finding "$out_dir/002-medium.md" medium duplication duplication src/medium.sh
write_finding "$out_dir/003-high.md" high complexity high-risk src/high.sh
write_finding "$out_dir/004-critical.md" critical type-safety critical-risk src/critical.sh

export REPOLENS_MIN_SEVERITY=high
build_round_digest "$round_dir" 2>"$TMPDIR/digest.err"
digest="$(cat "$round_dir/digest.md")"

assert_contains "high finding is recorded" "complexity: 1 finding" "$digest"
assert_contains "critical finding is recorded" "type-safety: 1 finding" "$digest"
assert_contains "high theme is recorded" "high-risk" "$digest"
assert_contains "critical theme is recorded" "critical-risk" "$digest"
assert_not_contains "low finding is filtered" "dead-code" "$digest"
assert_not_contains "medium finding is filtered" "duplication: 1 finding" "$digest"
assert_not_contains "low theme is filtered" "polish" "$digest"
assert_not_contains "medium theme is filtered" "duplication (1)" "$digest"

finish
