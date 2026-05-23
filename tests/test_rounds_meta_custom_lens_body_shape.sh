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

# Tests for issue #231: custom lens body shape must not include the raw
# dispatch bullet (- CUSTOM: ...) or the "Draft prompt:" label.
# shellcheck disable=SC2034,SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/streak.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-meta-custom-lens-body-shape"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

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
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect to find: $needle"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
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

log_info() { LOG_LINES+=("INFO:$*"); }
log_warn() { LOG_LINES+=("WARN:$*"); }

echo "=== CUSTOM lens-body shape: no leftover dispatch metadata (issue #231) ==="

write_lens security injection
LENSES_DIR="$TMPDIR/lenses"
MODE="audit"
LOG_LINES=()

echo ""
echo "Test 1: fenced CUSTOM produces lens body without raw dispatch bullet"
cat > "$TMPDIR/meta-output.txt" <<'EOF'
## Round 3 dispatch plan
- CUSTOM: payment-retry-race role=deeper - `lib/billing/retry.go:84`; idempotency key derivation suspicious.
  ```prompt
  ## Focus
  Inspect lib/billing/retry.go:84 for retry races.
  ## Approach
  Trace concurrent retries.
  ## Output
  One finding per concrete race window.
  ```
HYPOTHESES_TO_VERIFY:
- Verify retry race.
EOF

_rounds_meta_parse_output "$TMPDIR/meta-output.txt" "$TMPDIR/dispatch.md" "$TMPDIR/hypotheses.md" "$LENSES_DIR"

mkdir -p "$TMPDIR/custom-out"
_rounds_meta_dispatch_custom_entries "$TMPDIR/dispatch.md" "$TMPDIR/custom-out" >/dev/null

lens_file="$TMPDIR/custom-out/custom/payment-retry-race.md"
TOTAL=$((TOTAL + 1))
if [[ -f "$lens_file" ]]; then
  pass_with "fenced CUSTOM lens file written"
else
  fail_with "fenced CUSTOM lens file written" "Expected $lens_file"
fi

lens_body="$(cat "$lens_file")"

# Body contains the focus prose.
assert_contains "lens body retains focus instruction" "Inspect lib/billing/retry.go:84 for retry races." "$lens_body"
assert_contains "lens body retains approach instruction" "Trace concurrent retries." "$lens_body"
assert_contains "lens body retains output instruction" "One finding per concrete race window." "$lens_body"

# Body MUST NOT contain leftover dispatch metadata.
assert_not_contains "lens body has no '- CUSTOM:' line" "- CUSTOM:" "$lens_body"
# Check no body line starts with 'CUSTOM:' under the Expert Focus header.
focus_section="$(awk '/^## Your Expert Focus/{found=1; next} found' "$lens_file")"
assert_not_contains "expert-focus section has no CUSTOM: bullet" "CUSTOM:" "$focus_section"
assert_not_contains "expert-focus section has no rationale fragment" "idempotency key derivation suspicious" "$focus_section"
assert_not_contains "expert-focus section has no fence ticks" '```' "$focus_section"

echo ""
echo "Test 2: unfenced legacy CUSTOM also drops dispatch bullet from body"
cat > "$TMPDIR/meta-flat.txt" <<'EOF'
## Round 3 dispatch plan
- CUSTOM: auth-followup role=broader missed_angle="token refresh" - `lib/auth.sh:1`; rationale.
  Draft prompt:
  Investigate token refresh path without rediscovering prior suspect sites.
HYPOTHESES_TO_VERIFY:
- Verify token refresh.
EOF
_rounds_meta_parse_output "$TMPDIR/meta-flat.txt" "$TMPDIR/dispatch-flat.md" "$TMPDIR/hypotheses-flat.md" "$LENSES_DIR"
mkdir -p "$TMPDIR/custom-out-flat"
_rounds_meta_dispatch_custom_entries "$TMPDIR/dispatch-flat.md" "$TMPDIR/custom-out-flat" >/dev/null

flat_lens="$TMPDIR/custom-out-flat/custom/auth-followup.md"
flat_lens_body="$(cat "$flat_lens")"

assert_contains "unfenced lens body retains focus prose" "Investigate token refresh path" "$flat_lens_body"

flat_focus="$(awk '/^## Your Expert Focus/{found=1; next} found' "$flat_lens")"
assert_not_contains "unfenced expert-focus section has no CUSTOM: bullet" "CUSTOM:" "$flat_focus"
assert_not_contains "unfenced expert-focus section has no Draft prompt label" "Draft prompt:" "$flat_focus"
assert_not_contains "unfenced expert-focus section has no rationale fragment" "rationale." "$flat_focus"

echo ""
echo "Test 3: lens body has correct Category line and ## Your Expert Focus header"
TOTAL=$((TOTAL + 1))
first_two_section_lines="$(grep -A1 '^## Your Expert Focus' "$lens_file" | tail -n +2 | head -n 2 | tr -d '\n')"
# Should start with "Category: payment-retry-race"
if grep -q '^Category: payment-retry-race$' "$lens_file"; then
  pass_with "lens has Category line after Expert Focus header"
else
  fail_with "lens has Category line after Expert Focus header" "Lens content: $first_two_section_lines"
fi

finish
