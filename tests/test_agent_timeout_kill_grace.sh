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

# Integration coverage for issue #113: timeout(1) sends SIGTERM at the
# per-agent cap, waits REPOLENS_AGENT_KILL_GRACE seconds, and escalates to
# SIGKILL for TERM-resistant agents while preserving child cleanup.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
RUN_IDS=()
trap 'rm -rf "$TMPDIR"; for run_id in "${RUN_IDS[@]:-}"; do [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id" || true; done' EXIT

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (needle='$needle' not found)"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (unexpected needle='$needle')"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

assert_true() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
  fi
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  (
    cd "$project" || exit 1
    git init -q 2>/dev/null
    git config user.email test@example.com
    git config user.name Test
    echo "# test" > README.md
    git add README.md
    git commit -q -m init 2>/dev/null
  ) || true
}

run_repolens_with_fake_codex() {
  local fake_bin="$1" marker="$2" out_file="$3" project="$4"
  PATH="$fake_bin:$PATH" \
    FAKE_AGENT_MARKER="$marker" \
    REPOLENS_AGENT_TIMEOUT=1 \
    REPOLENS_AGENT_KILL_GRACE=1 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$project" \
      --agent codex \
      --focus i18n-strings \
      --mode audit \
      --local \
      --yes \
      --max-issues 1 \
      >"$out_file" 2>&1
}

extract_run_id() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" | head -1 | awk '{print $3}')"
  printf '%s\n' "$run_id"
}

collect_iteration_output() {
  local run_id="$1"
  if [[ -n "$run_id" && -d "$SCRIPT_DIR/logs/$run_id" ]]; then
    find "$SCRIPT_DIR/logs/$run_id" -type f -name 'iteration-*.txt' -exec cat {} +
  fi
}

echo "=== agent timeout kill grace escalation ==="

if ! command -v timeout >/dev/null 2>&1; then
  echo "  SKIP: timeout(1) not available on this system"
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit 0
fi

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: git and jq are required for orchestrator integration checks"
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit 0
fi

echo ""
echo "=== Clean SIGTERM path ==="

CLEAN_PROJECT="$TMPDIR/clean-project"
make_project "$CLEAN_PROJECT"
CLEAN_BIN="$TMPDIR/clean-bin"
mkdir -p "$CLEAN_BIN"
CLEAN_MARKER="$TMPDIR/clean-calls"
: > "$CLEAN_MARKER"
cat > "$CLEAN_BIN/codex" <<'SH'
#!/usr/bin/env bash
marker="${FAKE_AGENT_MARKER:?marker path required}"
calls="$(wc -l < "$marker")"
echo call >> "$marker"
if (( calls == 0 )); then
  trap 'echo caught SIGTERM; exit 0' TERM
  while true; do
    sleep 1
  done
fi
echo "Analysis complete. No findings."
echo "DONE"
SH
chmod +x "$CLEAN_BIN/codex"

CLEAN_OUT="$TMPDIR/clean-run.log"
START_EPOCH="$(date +%s)"
set +e
run_repolens_with_fake_codex "$CLEAN_BIN" "$CLEAN_MARKER" "$CLEAN_OUT" "$CLEAN_PROJECT"
clean_rc=$?
set -e
END_EPOCH="$(date +%s)"
clean_elapsed=$((END_EPOCH - START_EPOCH))
clean_run_id="$(extract_run_id "$CLEAN_OUT")"
[[ -n "$clean_run_id" ]] && RUN_IDS+=("$clean_run_id")
clean_log="$(cat "$CLEAN_OUT")"
clean_iterations="$(collect_iteration_output "$clean_run_id")"

assert_eq "Clean TERM run exits successfully" "0" "$clean_rc"
assert_contains "Clean TERM agent output is captured" "caught SIGTERM" "$clean_iterations"
assert_contains "Clean TERM log uses exited-during-grace wording" "exited during 1s grace" "$clean_log"
assert_not_contains "Clean TERM log does not report hard kill" "hard-killed after 1s grace" "$clean_log"
TOTAL=$((TOTAL + 1))
if (( clean_elapsed < 10 )); then
  PASS=$((PASS + 1))
  echo "  PASS: Clean TERM run completed in ${clean_elapsed}s"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Clean TERM run took ${clean_elapsed}s"
fi

echo ""
echo "=== Hard SIGKILL path ==="

HARD_PROJECT="$TMPDIR/hard-project"
make_project "$HARD_PROJECT"
HARD_BIN="$TMPDIR/hard-bin"
mkdir -p "$HARD_BIN"
HARD_MARKER="$TMPDIR/hard-calls"
: > "$HARD_MARKER"
cat > "$HARD_BIN/codex" <<'SH'
#!/usr/bin/env bash
marker="${FAKE_AGENT_MARKER:?marker path required}"
calls="$(wc -l < "$marker")"
echo call >> "$marker"
if (( calls == 0 )); then
  trap '' TERM
  sleep 30
fi
echo "Analysis complete. No findings."
echo "DONE"
SH
chmod +x "$HARD_BIN/codex"

HARD_OUT="$TMPDIR/hard-run.log"
START_EPOCH="$(date +%s)"
set +e
run_repolens_with_fake_codex "$HARD_BIN" "$HARD_MARKER" "$HARD_OUT" "$HARD_PROJECT"
hard_rc=$?
set -e
END_EPOCH="$(date +%s)"
hard_elapsed=$((END_EPOCH - START_EPOCH))
hard_run_id="$(extract_run_id "$HARD_OUT")"
[[ -n "$hard_run_id" ]] && RUN_IDS+=("$hard_run_id")
hard_log="$(cat "$HARD_OUT")"

assert_eq "Hard kill run exits successfully after recovery" "0" "$hard_rc"
assert_contains "Hard kill log uses hard-killed wording" "hard-killed after 1s grace" "$hard_log"
assert_contains "Hard kill log includes timeout cap" "agent timed out after 1s" "$hard_log"
TOTAL=$((TOTAL + 1))
if (( hard_elapsed < 10 )); then
  PASS=$((PASS + 1))
  echo "  PASS: Hard kill run completed in ${hard_elapsed}s"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Hard kill run took ${hard_elapsed}s"
fi

echo ""
echo "=== Child process cleanup ==="

# shellcheck disable=SC1090,SC1091
source "$CORE"
CHILD_PROJECT="$TMPDIR/child-project"
mkdir -p "$CHILD_PROJECT"
CHILD_BIN="$TMPDIR/child-bin"
mkdir -p "$CHILD_BIN"
CHILD_PID_FILE="$TMPDIR/child.pid"
cat > "$CHILD_BIN/codex" <<'SH'
#!/usr/bin/env bash
sleep 30 &
echo "$!" > "${FAKE_CHILD_PID_FILE:?child pid path required}"
wait
SH
chmod +x "$CHILD_BIN/codex"

CHILD_OUT="$TMPDIR/child-run.log"
set +e
(
  export PATH="$CHILD_BIN:$PATH"
  export FAKE_CHILD_PID_FILE="$CHILD_PID_FILE"
  run_agent codex "test prompt" "$CHILD_PROJECT" 1 1
) >"$CHILD_OUT" 2>&1
child_rc=$?
set -e

assert_eq "Child cleanup run_agent returns clean timeout status" "124" "$child_rc"
TOTAL=$((TOTAL + 1))
if [[ -s "$CHILD_PID_FILE" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Child PID was captured"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Child PID was not captured"
fi

child_pid="$(cat "$CHILD_PID_FILE" 2>/dev/null || true)"
child_gone=1
if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      child_gone=0
      break
    fi
    sleep 1
  done
  if [[ "$child_gone" -ne 0 ]]; then
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
fi
assert_true "Child process is gone after timeout" "$child_gone"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
