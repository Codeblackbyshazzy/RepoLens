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

# Integration test for issue #115 interruptibility: a Ctrl-C/SIGINT while
# RepoLens is sleeping for a parseable agent rate-limit resume must stop the
# run promptly instead of leaving a blocked sleep behind.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_SLEEP="$(command -v sleep)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
RUN_ID=""

# shellcheck disable=SC2329
cleanup() {
  if [[ -n "${RUN_PID:-}" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
    kill -TERM "-$RUN_PID" 2>/dev/null || kill -TERM "$RUN_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
  [[ -n "$RUN_ID" ]] && rm -rf "$SCRIPT_DIR/logs/$RUN_ID"
}
trap cleanup EXIT

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

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (missing '$file')"
  fi
}

echo "=== Rate-limit sleep is interruptible ==="

PROJECT="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
STATE="$TMPDIR/codex-count"
SLEEP_LOG="$TMPDIR/sleep.log"
SLEEP_STARTED="$TMPDIR/sleep-started"
OUT_FILE="$TMPDIR/run.log"
mkdir -p "$PROJECT" "$FAKE_BIN"
git -C "$PROJECT" init -q 2>/dev/null || true
printf '# test project\n' > "$PROJECT/README.md"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
count=0
if [[ -f "${REPOLENS_TEST_STATE:?}" ]]; then
  count="$(cat "$REPOLENS_TEST_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$REPOLENS_TEST_STATE"
echo "ERROR: You've hit your usage limit. Please try again in 30 seconds."
exit 1
SH
chmod +x "$FAKE_BIN/codex"

cat > "$FAKE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "${REPOLENS_TEST_SLEEP_LOG:?}"
touch "${REPOLENS_TEST_SLEEP_STARTED:?}"
trap 'printf "interrupted\n" >> "${REPOLENS_TEST_SLEEP_LOG:?}"; exit 130' INT TERM
while :; do
  "${REPOLENS_TEST_REAL_SLEEP:?}" 1
done
SH
chmod +x "$FAKE_BIN/sleep"

export PATH="$FAKE_BIN:$PATH"
export REPOLENS_TEST_STATE="$STATE"
export REPOLENS_TEST_SLEEP_LOG="$SLEEP_LOG"
export REPOLENS_TEST_SLEEP_STARTED="$SLEEP_STARTED"
export REPOLENS_TEST_REAL_SLEEP="$REAL_SLEEP"
export REPOLENS_RATE_LIMIT_MAX_SLEEP=120
export REPOLENS_AGENT_TIMEOUT=10

if command -v setsid >/dev/null 2>&1; then
  setsid bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --focus i18n-strings \
    --mode audit \
    --local \
    --max-issues 99 \
    --yes \
    >"$OUT_FILE" 2>&1 &
else
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --focus i18n-strings \
    --mode audit \
    --local \
    --max-issues 99 \
    --yes \
    >"$OUT_FILE" 2>&1 &
fi
RUN_PID=$!

for _ in $(seq 1 40); do
  [[ -f "$SLEEP_STARTED" ]] && break
  if ! kill -0 "$RUN_PID" 2>/dev/null; then
    break
  fi
  "$REAL_SLEEP" 0.25
done

RUN_ID="$(grep -oE 'RepoLens run [^ ]+ starting' "$OUT_FILE" | head -1 | awk '{print $3}')"
assert_file_exists "Retry sleep started" "$SLEEP_STARTED"

if kill -0 "$RUN_PID" 2>/dev/null; then
  kill -INT "-$RUN_PID" 2>/dev/null || kill -INT "$RUN_PID" 2>/dev/null || true
fi

for _ in $(seq 1 40); do
  if ! kill -0 "$RUN_PID" 2>/dev/null; then
    break
  fi
  "$REAL_SLEEP" 0.25
done

TOTAL=$((TOTAL + 1))
if kill -0 "$RUN_PID" 2>/dev/null; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: RepoLens process was still running after SIGINT"
  kill -TERM "-$RUN_PID" 2>/dev/null || kill -TERM "$RUN_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if ! kill -0 "$RUN_PID" 2>/dev/null; then
      break
    fi
    "$REAL_SLEEP" 0.25
  done
  if kill -0 "$RUN_PID" 2>/dev/null; then
    kill -KILL "-$RUN_PID" 2>/dev/null || kill -KILL "$RUN_PID" 2>/dev/null || true
  fi
else
  PASS=$((PASS + 1))
  echo "  PASS: RepoLens process exited after SIGINT"
fi

wait "$RUN_PID" 2>/dev/null
exit_code=$?
TOTAL=$((TOTAL + 1))
if [[ "$exit_code" -ne 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Interrupted run exits non-zero"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Interrupted run exited 0"
fi

sleep_log_contents="$(cat "$SLEEP_LOG" 2>/dev/null || true)"
assert_contains "Sleep command received interrupt/termination" "interrupted" "$sleep_log_contents"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
