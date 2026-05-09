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

# Tests for the --depth flag and deprecated DONE_STREAK_REQUIRED alias.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_PARENT="$SCRIPT_DIR/logs/test-depth-flag"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}

trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0
FAKE_BIN="$TMPDIR/bin"
LAST_OUTPUT_FILE=""
LAST_COUNT_FILE=""
LAST_RC=0

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
    fail_with "$desc" "Expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect output to contain: $needle"
  fi
}

make_fake_codex() {
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'run\n' >> "$REPOLENS_DEPTH_COUNT"
printf 'DONE\n'
EOF
  chmod +x "$FAKE_BIN/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# depth test\n' > "$project/README.md"
}

run_repolens_case() {
  local name="$1"
  local env_depth="$2"
  shift 2

  local project="$TMPDIR/project-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/output-$name.txt"
  LAST_COUNT_FILE="$TMPDIR/count-$name.txt"
  : > "$LAST_COUNT_FILE"

  local env_args=(env -u DONE_STREAK_REQUIRED PATH="$FAKE_BIN:$PATH" REPOLENS_DEPTH_COUNT="$LAST_COUNT_FILE")
  if [[ -n "$env_depth" ]]; then
    env_args=(env PATH="$FAKE_BIN:$PATH" REPOLENS_DEPTH_COUNT="$LAST_COUNT_FILE" DONE_STREAK_REQUIRED="$env_depth")
  fi

  "${env_args[@]}" bash "$SCRIPT_DIR/repolens.sh" \
    --project "$project" \
    --agent codex \
    --focus naming \
    --local \
    --output "$TMPDIR/issues-$name" \
    --yes \
    "$@" >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
}

run_discover_case() {
  local name="$1"
  local env_depth="$2"
  shift 2

  local project="$TMPDIR/project-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/output-$name.txt"
  LAST_COUNT_FILE="$TMPDIR/count-$name.txt"
  : > "$LAST_COUNT_FILE"

  local env_args=(env -u DONE_STREAK_REQUIRED PATH="$FAKE_BIN:$PATH" REPOLENS_DEPTH_COUNT="$LAST_COUNT_FILE")
  if [[ -n "$env_depth" ]]; then
    env_args=(env PATH="$FAKE_BIN:$PATH" REPOLENS_DEPTH_COUNT="$LAST_COUNT_FILE" DONE_STREAK_REQUIRED="$env_depth")
  fi

  "${env_args[@]}" bash "$SCRIPT_DIR/repolens.sh" \
    --project "$project" \
    --agent codex \
    --mode discover \
    --focus monetization \
    --local \
    --output "$TMPDIR/issues-$name" \
    --yes \
    "$@" >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
}

agent_call_count() {
  wc -l < "$LAST_COUNT_FILE" | tr -d ' '
}

last_output() {
  cat "$LAST_OUTPUT_FILE"
}

register_created_run_id() {
  local run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$LAST_OUTPUT_FILE" 2>/dev/null | head -1 | awk '{print $3}')"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

warning_count() {
  grep -cF 'DONE_STREAK_REQUIRED is deprecated; use --depth N instead' "$LAST_OUTPUT_FILE" 2>/dev/null || true
}

echo ""
echo "=== Test Suite: --depth flag ==="
echo ""

make_fake_codex

echo "Test 1: --depth flag controls DONE streak"
run_repolens_case "flag-depth" "" --depth 2
register_created_run_id
assert_eq "--depth 2 exits successfully" "0" "$LAST_RC"
assert_eq "--depth 2 runs fake agent twice" "2" "$(agent_call_count)"
assert_contains "--depth 2 logs DONE x2" "DONE x2" "$(last_output)"

echo ""
echo "Test 2: DONE_STREAK_REQUIRED env alias controls depth and warns once"
run_repolens_case "env-depth" "2"
register_created_run_id
assert_eq "env alias exits successfully" "0" "$LAST_RC"
assert_eq "env alias runs fake agent twice" "2" "$(agent_call_count)"
assert_eq "env alias emits exactly one warning" "1" "$(warning_count)"

echo ""
echo "Test 3: --depth wins over DONE_STREAK_REQUIRED"
run_repolens_case "flag-wins" "3" --depth 2
register_created_run_id
assert_eq "flag plus env exits successfully" "0" "$LAST_RC"
assert_eq "flag wins and runs fake agent twice" "2" "$(agent_call_count)"
assert_eq "ignored env alias emits no warning" "0" "$(warning_count)"

echo ""
echo "Test 4: default audit depth remains 3"
run_repolens_case "default-audit" ""
register_created_run_id
assert_eq "audit default exits successfully" "0" "$LAST_RC"
assert_eq "audit default runs fake agent three times" "3" "$(agent_call_count)"

echo ""
echo "Test 5: default discover depth remains 1"
run_discover_case "default-discover" ""
register_created_run_id
assert_eq "discover default exits successfully" "0" "$LAST_RC"
assert_eq "discover default runs fake agent once" "1" "$(agent_call_count)"

echo ""
echo "Test 6: --depth rejects 0"
run_repolens_case "invalid-zero" "" --dry-run --depth 0
assert_eq "--depth 0 exits non-zero" "1" "$LAST_RC"
assert_contains "--depth 0 names bound" "--depth must be between 1 and 19 (exclusive of MAX_ITERATIONS_PER_LENS=20)" "$(last_output)"

echo ""
echo "Test 7: --depth rejects MAX_ITERATIONS_PER_LENS"
run_repolens_case "invalid-cap" "" --dry-run --depth 20
assert_eq "--depth 20 exits non-zero" "1" "$LAST_RC"
assert_contains "--depth 20 names bound" "--depth must be between 1 and 19 (exclusive of MAX_ITERATIONS_PER_LENS=20)" "$(last_output)"

echo ""
echo "Test 8: --depth rejects negative values"
run_repolens_case "invalid-negative" "" --dry-run --depth -1
assert_eq "--depth -1 exits non-zero" "1" "$LAST_RC"
assert_contains "--depth -1 names bound" "--depth must be between 1 and 19 (exclusive of MAX_ITERATIONS_PER_LENS=20)" "$(last_output)"

echo ""
echo "Test 9: --depth rejects non-numeric values"
run_repolens_case "invalid-text" "" --dry-run --depth abc
assert_eq "--depth abc exits non-zero" "1" "$LAST_RC"
assert_contains "--depth abc names bound" "--depth must be between 1 and 19 (exclusive of MAX_ITERATIONS_PER_LENS=20)" "$(last_output)"

echo ""
echo "Test 10: --depth rejects an explicitly empty value"
run_repolens_case "invalid-empty" "" --dry-run --depth ""
assert_eq "--depth empty exits non-zero" "1" "$LAST_RC"
assert_contains "--depth empty names bound" "--depth must be between 1 and 19 (exclusive of MAX_ITERATIONS_PER_LENS=20)" "$(last_output)"

echo ""
echo "Test 11: DONE_STREAK_REQUIRED validates the same upper bound"
run_repolens_case "invalid-env-cap" "20" --dry-run
assert_eq "invalid env exits non-zero" "1" "$LAST_RC"
assert_contains "invalid env names bound" "DONE_STREAK_REQUIRED must be between 1 and 19 (exclusive of MAX_ITERATIONS_PER_LENS=20)" "$(last_output)"

echo ""
echo "Test 12: usage documents --depth and deprecated env alias"
usage_output="$(bash "$SCRIPT_DIR/repolens.sh" --help 2>&1)"
assert_contains "usage includes --depth" "--depth <n>" "$usage_output"
assert_contains "usage marks env alias deprecated" "DONE_STREAK_REQUIRED     DEPRECATED alias for --depth" "$usage_output"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
