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

# Tests for issue #231: CUSTOM payload accumulator must not truncate at the
# first ## heading inside a fenced draft prompt.
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

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-meta-custom-payload-with-headers"
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

echo "=== CUSTOM payload preserves ## subheadings inside fence (issue #231) ==="

write_lens security injection
LENSES_DIR="$TMPDIR/lenses"
MODE="audit"
LOG_LINES=()

echo ""
echo "Test 1: fenced CUSTOM draft prompt with ## subheadings survives parse_output"
cat > "$TMPDIR/meta-output.txt" <<'EOF'
## Round 3 dispatch plan
- CUSTOM: payment-retry-race role=deeper - `lib/billing/retry.go:84`; idempotency key derivation suspicious.
  ```prompt
  ## Focus
  Inspect lib/billing/retry.go:84 for races in the retry handler.
  ## Approach
  Trace the idempotency-key derivation across concurrent retries.
  ## Output
  One finding per concrete race window with file:line evidence.
  ```
HYPOTHESES_TO_VERIFY:
- Verify retry race window.
EOF

_rounds_meta_parse_output "$TMPDIR/meta-output.txt" "$TMPDIR/dispatch.md" "$TMPDIR/hypotheses.md" "$LENSES_DIR"
rc=$?
dispatch="$(cat "$TMPDIR/dispatch.md")"
assert_eq "parse_output exits successfully" "0" "$rc"
assert_contains "dispatch preserves CUSTOM bullet" "CUSTOM: payment-retry-race" "$dispatch"
assert_contains "dispatch preserves ## Focus subheading" "## Focus" "$dispatch"
assert_contains "dispatch preserves ## Approach subheading" "## Approach" "$dispatch"
assert_contains "dispatch preserves ## Output subheading" "## Output" "$dispatch"
assert_contains "dispatch preserves focus instruction" "Inspect lib/billing/retry.go:84" "$dispatch"
assert_contains "dispatch preserves approach instruction" "Trace the idempotency-key derivation" "$dispatch"
assert_contains "dispatch preserves output instruction" "One finding per concrete race window" "$dispatch"

hypotheses="$(cat "$TMPDIR/hypotheses.md")"
assert_contains "hypotheses block captured after CUSTOM block" "Verify retry race window." "$hypotheses"

echo ""
echo "Test 2: dispatch_custom_entries writes complete lens file body"
mkdir -p "$TMPDIR/custom-out"
custom_entries="$(_rounds_meta_dispatch_custom_entries "$TMPDIR/dispatch.md" "$TMPDIR/custom-out")"
assert_contains "custom reader produces a tuple" "custom/payment-retry-race" "$custom_entries"

lens_file="$TMPDIR/custom-out/custom/payment-retry-race.md"
TOTAL=$((TOTAL + 1))
if [[ -f "$lens_file" ]]; then
  pass_with "custom lens file is written"
else
  fail_with "custom lens file is written" "Expected $lens_file"
fi

lens_body="$(cat "$lens_file")"
assert_contains "lens file contains ## Your Expert Focus header" "## Your Expert Focus" "$lens_body"
assert_contains "lens file contains Category line" "Category: payment-retry-race" "$lens_body"
assert_contains "lens file body retains ## Focus" "## Focus" "$lens_body"
assert_contains "lens file body retains ## Approach" "## Approach" "$lens_body"
assert_contains "lens file body retains ## Output" "## Output" "$lens_body"
assert_contains "lens file body retains focus instruction" "Inspect lib/billing/retry.go:84" "$lens_body"
assert_contains "lens file body retains output instruction" "One finding per concrete race window" "$lens_body"

echo ""
echo "Test 3: backward compatibility — unfenced CUSTOM payload still parses"
cat > "$TMPDIR/meta-flat.txt" <<'EOF'
## Round 3 dispatch plan
- CUSTOM: auth-followup role=broader missed_angle="token refresh" - `lib/auth.sh:1`; rationale.
  Draft prompt:
  Investigate token refresh path without rediscovering prior suspect sites.
HYPOTHESES_TO_VERIFY:
- Verify token refresh.
EOF
_rounds_meta_parse_output "$TMPDIR/meta-flat.txt" "$TMPDIR/dispatch-flat.md" "$TMPDIR/hypotheses-flat.md" "$LENSES_DIR"
flat_dispatch="$(cat "$TMPDIR/dispatch-flat.md")"
assert_contains "unfenced dispatch preserves CUSTOM" "CUSTOM: auth-followup" "$flat_dispatch"
assert_contains "unfenced dispatch preserves draft prompt body" "Investigate token refresh path" "$flat_dispatch"

mkdir -p "$TMPDIR/custom-out-flat"
flat_entries="$(_rounds_meta_dispatch_custom_entries "$TMPDIR/dispatch-flat.md" "$TMPDIR/custom-out-flat")"
assert_contains "unfenced custom reader keeps role+focus on tuple" "custom/auth-followup|broader|token refresh|" "$flat_entries"

flat_lens="$TMPDIR/custom-out-flat/custom/auth-followup.md"
flat_lens_body="$(cat "$flat_lens")"
assert_contains "unfenced lens file body contains focus instruction" "Investigate token refresh path" "$flat_lens_body"

echo ""
echo "Test 4: section boundary still terminates CUSTOM block after fence closes"
cat > "$TMPDIR/meta-boundary.txt" <<'EOF'
## Round 3 dispatch plan
- CUSTOM: race-conditions role=deeper - `lib/billing/retry.go:84`; race suspect.
  ```
  ## Focus
  Inspect for retry races.
  ```
## Round 4 dispatch plan
LENS: injection
HYPOTHESES_TO_VERIFY:
- Verify retry race.
EOF
_rounds_meta_parse_output "$TMPDIR/meta-boundary.txt" "$TMPDIR/dispatch-bnd.md" "$TMPDIR/hypotheses-bnd.md" "$LENSES_DIR"
mkdir -p "$TMPDIR/custom-out-bnd"
_rounds_meta_dispatch_custom_entries "$TMPDIR/dispatch-bnd.md" "$TMPDIR/custom-out-bnd" >/dev/null

bnd_lens="$TMPDIR/custom-out-bnd/custom/race-conditions.md"
bnd_lens_body="$(cat "$bnd_lens")"
assert_contains "fenced body retains focus heading" "## Focus" "$bnd_lens_body"
assert_not_contains "fenced body does not absorb next round heading" "Round 4 dispatch plan" "$bnd_lens_body"
assert_not_contains "fenced body does not absorb the next LENS line" "LENS: injection" "$bnd_lens_body"

echo ""
echo "Test 5: multiple CUSTOMs each with their own fenced ## headings"
cat > "$TMPDIR/meta-multi.txt" <<'EOF'
## Round 3 dispatch plan
- CUSTOM: alpha-leak role=deeper - `lib/alpha.go:10`; suspect leak.
  ```prompt
  ## Focus
  Alpha module leak.
  ## Output
  Alpha-specific finding.
  ```
- CUSTOM: beta-leak role=deeper - `lib/beta.go:20`; suspect leak.
  ```prompt
  ## Focus
  Beta module leak.
  ## Output
  Beta-specific finding.
  ```
HYPOTHESES_TO_VERIFY:
- Verify leaks.
EOF
_rounds_meta_parse_output "$TMPDIR/meta-multi.txt" "$TMPDIR/dispatch-multi.md" "$TMPDIR/hypotheses-multi.md" "$LENSES_DIR"
mkdir -p "$TMPDIR/custom-out-multi"
_rounds_meta_dispatch_custom_entries "$TMPDIR/dispatch-multi.md" "$TMPDIR/custom-out-multi" >/dev/null

alpha_lens="$TMPDIR/custom-out-multi/custom/alpha-leak.md"
beta_lens="$TMPDIR/custom-out-multi/custom/beta-leak.md"
TOTAL=$((TOTAL + 1))
if [[ -f "$alpha_lens" && -f "$beta_lens" ]]; then
  pass_with "two distinct lens files written"
else
  fail_with "two distinct lens files written" "alpha exists: $([[ -f $alpha_lens ]] && echo y || echo n) | beta exists: $([[ -f $beta_lens ]] && echo y || echo n)"
fi
alpha_body="$(cat "$alpha_lens")"
beta_body="$(cat "$beta_lens")"
assert_contains "alpha lens has its own focus" "Alpha module leak" "$alpha_body"
assert_not_contains "alpha lens does not leak beta focus" "Beta module leak" "$alpha_body"
assert_contains "beta lens has its own focus" "Beta module leak" "$beta_body"
assert_not_contains "beta lens does not leak alpha focus" "Alpha module leak" "$beta_body"

finish
