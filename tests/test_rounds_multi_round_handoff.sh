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

# Integration test for issue #180: --rounds 3 creates the round layout, carries
# prior digests into later prompts, writes between-round dispatch artifacts, and
# promotes a schema-valid final synthesizer manifest without real agent calls.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
RUN_LOG_DIR=""
KEEP_ARTIFACTS=0

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-multi-round-handoff"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    if [[ -n "$RUN_LOG_DIR" ]]; then
      rm -rf "$RUN_LOG_DIR"
    fi
    rm -rf "$TMPDIR"
    rmdir "$TMP_PARENT" 2>/dev/null || true
  else
    printf 'Preserved test artifacts: %s\n' "$TMPDIR"
    if [[ -n "$RUN_LOG_DIR" ]]; then
      printf 'Preserved RepoLens log dir: %s\n' "$RUN_LOG_DIR"
    fi
  fi
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
  KEEP_ARTIFACTS=1
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

assert_dir_exists() {
  local desc="$1" dir="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -d "$dir" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected directory at $dir"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

assert_file_absent() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect path at $file"
  fi
}

assert_nonempty_find() {
  local desc="$1" dir="$2"
  local matches
  TOTAL=$((TOTAL + 1))
  matches="$(find "$dir" -type f -name '*.md' -print -quit 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected at least one markdown file under $dir"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected rendered prompt to contain digest text"
  fi
}

assert_jq() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq assertion failed for $file: $filter"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== rounds --rounds 3 handoff integration (issue #180) ==="

PROJECT_DIR="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
MOCK_LOG="$TMPDIR/mock-agent.log"
BUG_FILE="$TMPDIR/bug-report.md"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"
git -C "$PROJECT_DIR" init -q
printf '# RepoLens issue 180 fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' commit -q -m 'fixture'

cat > "$BUG_FILE" <<'EOF'
The README example surfaces an injection-shaped concern when the project intro
is read at README.md:1. Investigate end-to-end.
EOF

cat > "$FAKE_BIN/codex" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/tests/mock-agent.sh" "\$@"
EOF
chmod +x "$FAKE_BIN/codex" "$SCRIPT_DIR/tests/mock-agent.sh"

run_output="$TMPDIR/repolens-output.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode bugreport \
    --bug-report "$BUG_FILE" \
    --focus injection \
    --rounds 3 \
    --depth 1 \
    --yes \
    >"$run_output" 2>&1
run_rc=$?

assert_eq "repolens.sh --rounds 3 exits successfully" "0" "$run_rc"
RUN_ID="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$run_output" | tail -1)"
if [[ -n "$RUN_ID" ]]; then
  RUN_LOG_DIR="$SCRIPT_DIR/logs/$RUN_ID"
fi
assert_eq "run id is discoverable from output" "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"

if [[ -z "$RUN_ID" || ! -d "$RUN_LOG_DIR" ]]; then
  fail_with "run log directory exists" "Could not resolve run log from $run_output"
  finish
fi

for round in 1 2 3; do
  round_dir="$RUN_LOG_DIR/rounds/round-$round"
  assert_dir_exists "round-$round directory exists" "$round_dir"
  assert_dir_exists "round-$round lens-outputs directory exists" "$round_dir/lens-outputs"
  assert_nonempty_find "round-$round lens-outputs contains markdown findings" "$round_dir/lens-outputs"
  assert_file_exists "round-$round digest.md exists" "$round_dir/digest.md"
  TOTAL=$((TOTAL + 1))
  if [[ -s "$round_dir/digest.md" ]]; then
    pass_with "round-$round digest.md is non-empty"
  else
    fail_with "round-$round digest.md is non-empty" "$round_dir/digest.md is empty"
  fi
  assert_file_exists "round-$round .completed barrier exists" "$round_dir/.completed"
  assert_file_exists "round-$round captured prompt exists" "$round_dir/captured-prompts/security__injection.prompt.md"
done

digest1="$(cat "$RUN_LOG_DIR/rounds/round-1/digest.md")"
digest2="$(cat "$RUN_LOG_DIR/rounds/round-2/digest.md")"
prompt2="$(cat "$RUN_LOG_DIR/rounds/round-2/captured-prompts/security__injection.prompt.md")"
prompt3="$(cat "$RUN_LOG_DIR/rounds/round-3/captured-prompts/security__injection.prompt.md")"

assert_contains "round-2 prompt contains exact round-1 digest text" "$digest1" "$prompt2"
assert_contains "round-3 prompt contains exact round-1 digest text" "$digest1" "$prompt3"
assert_contains "round-3 prompt contains exact round-2 digest text" "$digest2" "$prompt3"

assert_file_exists "round-1 dispatch.md exists" "$RUN_LOG_DIR/rounds/round-1/dispatch.md"
assert_file_exists "round-2 dispatch.md exists" "$RUN_LOG_DIR/rounds/round-2/dispatch.md"
assert_file_absent "round-3 dispatch.md is absent" "$RUN_LOG_DIR/rounds/round-3/dispatch.md"

manifest="$RUN_LOG_DIR/final/manifest.json"
assert_file_exists "final manifest.json exists" "$manifest"
assert_jq "manifest is valid JSON array" "$manifest" 'type == "array"'
assert_jq "manifest entries match synthesizer schema core fields" "$manifest" '
  length >= 1 and
  all(.[]; (
    (.title | type == "string" and length > 0) and
    (.severity | IN("critical", "high", "medium", "low")) and
    (.domain | type == "string" and length > 0) and
    (.lens | type == "string" and length > 0) and
    (.body | type == "string" and length > 0) and
    (.cluster_id | type == "string" and length > 0) and
    (.root_cause_category | type == "string" and length > 0) and
    (.source_finding_paths | type == "array" and length > 0) and
    (.dedup_against_existing | type == "array") and
    (.proposed_labels | type == "array") and
    (.cross_link_actions | type == "array") and
    (.granularity | IN("independent", "cluster"))
  ))
'

assert_eq "mock agent handled three lens prompts" "3" "$(grep -c '^lens$' "$MOCK_LOG" 2>/dev/null || printf '0')"
assert_eq "mock agent handled two meta prompts" "2" "$(grep -c '^meta$' "$MOCK_LOG" 2>/dev/null || printf '0')"
assert_eq "mock agent handled one synthesizer prompt" "1" "$(grep -c '^synthesizer$' "$MOCK_LOG" 2>/dev/null || printf '0')"
assert_eq "local multi-round run does not invoke filing agent" "0" "$(grep -c '^filing$' "$MOCK_LOG" 2>/dev/null || true)"
assert_file_absent "local multi-round run does not write filing marker" "$RUN_LOG_DIR/final/filed/mock-round-handoff.url"

finish
