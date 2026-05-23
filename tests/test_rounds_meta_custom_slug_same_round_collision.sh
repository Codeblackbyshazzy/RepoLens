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

# Issue #233 — within a single round, two CUSTOM categories that differ only
# in case/punctuation/whitespace slugify to the same base value. The writer
# must NOT silently overwrite the first lens; the second filename must be
# disambiguated with a -2 suffix.
# shellcheck disable=SC2034,SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-meta-custom-slug-same-round-collision"
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

echo "=== CUSTOM same-round slug collision counter (issue #233) ==="

write_lens security injection
LENSES_DIR="$TMPDIR/lenses"
MODE="audit"
unset CURRENT_ROUND_INDEX || true

cat > "$TMPDIR/meta-output.txt" <<'EOF'
## Round 2 dispatch plan
- CUSTOM: Payment retry race! role=deeper - `lib/billing/retry.go:84`; first variant.
  ```prompt
  ## Focus
  Inspect lib/billing/retry.go:84 for retry races (variant A).
  ```
- CUSTOM: payment-retry race role=deeper - `lib/billing/retry.go:120`; second variant differs in punctuation.
  ```prompt
  ## Focus
  Inspect lib/billing/retry.go:120 for retry races (variant B).
  ```
HYPOTHESES_TO_VERIFY:
- Verify retry race windows.
EOF

_rounds_meta_parse_output "$TMPDIR/meta-output.txt" "$TMPDIR/dispatch.md" "$TMPDIR/hypotheses.md" "$LENSES_DIR"
rc=$?
assert_eq "parse_output exits cleanly" "0" "$rc"

mkdir -p "$TMPDIR/custom-out"
entries="$(_rounds_meta_dispatch_custom_entries "$TMPDIR/dispatch.md" "$TMPDIR/custom-out")"

echo ""
echo "Test 1: both distinct categories produce lens files (no overwrite)"
first_lens="$TMPDIR/custom-out/custom/payment-retry-race.md"
second_lens="$TMPDIR/custom-out/custom/payment-retry-race-2.md"
TOTAL=$((TOTAL + 1))
if [[ -f "$first_lens" ]]; then
  pass_with "first lens file written at payment-retry-race.md"
else
  fail_with "first lens file written at payment-retry-race.md" "Missing"
fi

TOTAL=$((TOTAL + 1))
if [[ -f "$second_lens" ]]; then
  pass_with "second lens file written at payment-retry-race-2.md (disambiguated)"
else
  fail_with "second lens file written at payment-retry-race-2.md (disambiguated)" "Missing — silent overwrite suspected"
fi

echo ""
echo "Test 2: first lens body is variant A (not overwritten)"
first_body="$(cat "$first_lens")"
assert_contains "first lens retains variant A focus" "variant A" "$first_body"

echo ""
echo "Test 3: second lens body is variant B"
if [[ -f "$second_lens" ]]; then
  second_body="$(cat "$second_lens")"
  assert_contains "second lens retains variant B focus" "variant B" "$second_body"
fi

echo ""
echo "Test 4: dispatch tuples reference two distinct slugs"
assert_contains "tuples mention payment-retry-race entry" "custom/payment-retry-race" "$entries"
assert_contains "tuples mention payment-retry-race-2 entry" "custom/payment-retry-race-2" "$entries"

finish
