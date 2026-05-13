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

# Tests for issue #203: lib/filing.sh must be loaded by the production
# entrypoint so the filing dispatcher is reachable outside direct unit tests.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"
FILING_LIB="$SCRIPT_DIR/lib/filing.sh"

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
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle'"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== repolens.sh sources filing pipeline ==="

source_line='source "$SCRIPT_DIR/lib/filing.sh"'
repolens_source="$(< "$REPOLENS_SH")"

assert_contains "repolens.sh loads lib/filing.sh" "$source_line" "$repolens_source"

# Guard the test itself against a typo in the expected public symbol: this is
# the API that must be reachable once repolens.sh sources lib/filing.sh.
symbol_check="$(
  bash -c '
    set -uo pipefail
    source "$1"
    declare -F dispatch_filing_batch
  ' bash "$FILING_LIB" 2>/dev/null
)"
symbol_rc=$?

assert_success "lib/filing.sh exports dispatch_filing_batch" "$symbol_rc"
assert_contains "dispatch_filing_batch is the exported function" \
  "dispatch_filing_batch" "$symbol_check"

source_block="$(
  awk '
    /^# --- Source libraries ---$/ { in_source_block = 1; next }
    /^VERSION=/ { in_source_block = 0 }
    in_source_block { print }
  ' "$REPOLENS_SH"
)"

entrypoint_symbol_check="$(
  bash -c '
    set -uo pipefail
    SCRIPT_DIR="$1"
    eval "$2"
    declare -F dispatch_filing_batch
  ' bash "$SCRIPT_DIR" "$source_block" 2>/dev/null
)"
entrypoint_symbol_rc=$?

assert_success "repolens.sh source block makes dispatch_filing_batch reachable" "$entrypoint_symbol_rc"
assert_contains "dispatch_filing_batch is reachable after entrypoint sources" \
  "dispatch_filing_batch" "$entrypoint_symbol_check"

finish
