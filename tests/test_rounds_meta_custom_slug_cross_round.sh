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

# Issue #233 — CUSTOM slugs must not collide across rounds in summary.json.
# Two rounds emitting the same agent-named category must produce two
# distinct lens slugs (r2-..., r3-...) and two distinct summary.json rows
# carrying a `round` field.
# shellcheck disable=SC2034,SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/locking.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-meta-custom-slug-cross-round"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  [[ -n "${2:-}" ]] && printf '    %s\n' "$2"
}

assert_eq() {
  TOTAL=$((TOTAL + 1))
  if [[ "$2" == "$3" ]]; then
    pass_with "$1"
  else
    fail_with "$1" "Expected: $2 | Actual: $3"
  fi
}

assert_contains() {
  TOTAL=$((TOTAL + 1))
  if [[ "$3" == *"$2"* ]]; then
    pass_with "$1"
  else
    fail_with "$1" "Expected to find: $2"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  (( FAIL > 0 )) && exit 1
  exit 0
}

write_lens() {
  local domain="$1" lens="$2" dir
  dir="$TMPDIR/lenses/$domain"
  mkdir -p "$dir"
  cat > "$dir/$lens.md" <<EOF
---
id: $lens
domain: $domain
name: $lens
role: tester
---
## Your Expert Focus
Test lens.
EOF
}

log_info() { :; }
log_warn() { :; }

echo "=== CUSTOM slug cross-round disambiguation (issue #233) ==="

write_lens security injection
LENSES_DIR="$TMPDIR/lenses"
MODE="audit"

# Simulate round 2 — write the same payload to a per-round dir,
# then record_lens with CURRENT_ROUND_INDEX=2.
SUMMARY_FILE="$TMPDIR/summary.json"
init_summary "$SUMMARY_FILE" "test-cross-round" "$TMPDIR/project" "audit" "claude" "" ""

PAYLOAD='- CUSTOM: payment-retry-race role=deeper - `lib/billing/retry.go:84`; idempotency key derivation suspicious.
  ```prompt
  ## Focus
  Inspect lib/billing/retry.go:84 for retry races.
  ```'

mkdir -p "$TMPDIR/r2/custom-lenses"
mkdir -p "$TMPDIR/r3/custom-lenses"

echo ""
echo "Test 1: round 2 writer prepends r2- prefix to slug"
CURRENT_ROUND_INDEX=2
r2_entry="$(_rounds_meta_write_custom_lens "$TMPDIR/r2/custom-lenses" "$PAYLOAD" 1)"
assert_eq "round 2 writer emits r2-prefixed slug" "custom/r2-payment-retry-race" "$r2_entry"
TOTAL=$((TOTAL + 1))
if [[ -f "$TMPDIR/r2/custom-lenses/custom/r2-payment-retry-race.md" ]]; then
  pass_with "round 2 lens file exists at r2-prefixed path"
else
  fail_with "round 2 lens file exists at r2-prefixed path" "Missing $TMPDIR/r2/custom-lenses/custom/r2-payment-retry-race.md"
fi
record_lens "$SUMMARY_FILE" "custom" "r2-payment-retry-race" 1 "completed" 0 0

echo ""
echo "Test 2: round 3 writer prepends r3- prefix to slug"
CURRENT_ROUND_INDEX=3
r3_entry="$(_rounds_meta_write_custom_lens "$TMPDIR/r3/custom-lenses" "$PAYLOAD" 1)"
assert_eq "round 3 writer emits r3-prefixed slug" "custom/r3-payment-retry-race" "$r3_entry"
TOTAL=$((TOTAL + 1))
if [[ -f "$TMPDIR/r3/custom-lenses/custom/r3-payment-retry-race.md" ]]; then
  pass_with "round 3 lens file exists at r3-prefixed path"
else
  fail_with "round 3 lens file exists at r3-prefixed path" "Missing"
fi
record_lens "$SUMMARY_FILE" "custom" "r3-payment-retry-race" 1 "completed" 0 0

echo ""
echo "Test 3: summary.json contains two distinct CUSTOM rows with distinct slugs"
row_count="$(jq '[.lenses[] | select(.domain == "custom")] | length' "$SUMMARY_FILE")"
assert_eq "two custom rows recorded" "2" "$row_count"

distinct_slugs="$(jq -r '[.lenses[] | select(.domain == "custom") | .lens] | unique | length' "$SUMMARY_FILE")"
assert_eq "two distinct slugs (no collision)" "2" "$distinct_slugs"

echo ""
echo "Test 4: summary.json rows carry round field"
round2_row="$(jq -r '.lenses[] | select(.lens == "r2-payment-retry-race") | .round' "$SUMMARY_FILE")"
assert_eq "round 2 row carries round=2" "2" "$round2_row"
round3_row="$(jq -r '.lenses[] | select(.lens == "r3-payment-retry-race") | .round' "$SUMMARY_FILE")"
assert_eq "round 3 row carries round=3" "3" "$round3_row"

echo ""
echo "Test 5: record_lens without CURRENT_ROUND_INDEX defaults round to 0"
SUMMARY_DEFAULT="$TMPDIR/summary-default.json"
init_summary "$SUMMARY_DEFAULT" "test-default-round" "$TMPDIR/project" "audit" "claude" "" ""
unset CURRENT_ROUND_INDEX
record_lens "$SUMMARY_DEFAULT" "security" "injection" 1 "completed" 0 0
default_round="$(jq -r '.lenses[0].round' "$SUMMARY_DEFAULT")"
assert_eq "default round=0 when CURRENT_ROUND_INDEX unset" "0" "$default_round"

finish
