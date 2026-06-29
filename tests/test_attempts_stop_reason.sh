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

# Tests for issue #375 — Record stop-reason + completed-lens snapshot into
# `attempts.json` on abort. This EXTENDS the #371 writer so each per-attempt
# entry is useful for triage.
#
# Behavioral contract (from the issue's acceptance criteria):
#   - After a run that hits `.rate-limit-abort`, its attempt entry carries a
#     `why_stopped` reflecting the rate-limit reason, the correct completed
#     counts (`lenses_completed_total`, `lenses_completed_this_attempt`), and an
#     `exit_code` matching the process exit code.
#   - After resuming and finishing, the SECOND attempt entry shows
#     `lenses_completed_this_attempt` = lenses completed in THAT pass (the
#     per-attempt delta, NOT the cumulative total) and a `finished` /
#     `finished-empty` status, with `exit_code == 0`.
#   - A write failure never changes the run exit code (covered structurally by
#     the non-fatal contract; asserted in tests/test_attempts_json.sh Test 4).
#
# Strategy (NO real model — CLAUDE.md hard rule): a fake `codex` on PATH drives
# both attempts deterministically.
#   - Attempt 1 stub: the FIRST agent call returns `DONE` (completing the first
#     i18n lens at --depth 1), then every subsequent call emits a rate-limit
#     signature and exits non-zero — forcing a `.rate-limit-abort` on the SECOND
#     lens. The run therefore completes exactly one lens before aborting, so the
#     cumulative total later exceeds the resume pass's per-attempt delta (the
#     distinction the issue exists to make visible).
#   - Attempt 2 stub: a plain `DONE` emitter; --resume re-runs only the pending
#     (rate-limited) lens and finishes the run.
#
# Run-id discovery uses the "RepoLens run <id> starting" line (emitted for every
# invocation). Completed-lens counts are read directly from `.completed`
# (one `domain/lens` id per line) so the count assertions are robust regardless
# of exactly where the abort lands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_PARENT="$SCRIPT_DIR/logs/test-attempts-stop-reason"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

# shellcheck disable=SC2329  # cleanup is invoked indirectly via 'trap cleanup EXIT' below.
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

# assert_ok <desc> <cmd...> — passes iff the command exits 0. Used for every
# JSON content assertion so a MISSING field/file (the TDD red phase, or a real
# regression) makes the check FAIL rather than silently passing.
assert_ok() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "command failed: $*"
  fi
}

discover_run_id() {
  grep -oE 'RepoLens run [^ ]+ starting' "$1" 2>/dev/null | head -1 | awk '{print $3}'
}

# completed_count <run-id> — line count of logs/<run-id>/.completed (0 if absent).
completed_count() {
  local f="$SCRIPT_DIR/logs/$1/.completed"
  [[ -f "$f" ]] || { printf '0'; return 0; }
  grep -c '' "$f" 2>/dev/null || printf '0'
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# attempts stop-reason fixture\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" \
    -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' \
    commit -q -m 'fixture'
}

echo ""
echo "=== Test Suite: attempts.json stop-reason + completed snapshot (issue #375) ==="
echo ""

PROJECT_DIR="$TMPDIR/proj"
make_project "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# Attempt 1 — rate-limit abort.
# i18n has exactly two lenses (i18n-strings, i18n-formatting). Sequential run at
# --depth 1: first lens completes on its single DONE call; the second lens hits
# the rate-limit signature and the run aborts with a .rate-limit-abort sentinel.
# ---------------------------------------------------------------------------
echo "Attempt 1: a rate-limit abort records why_stopped + completed counts + exit_code"

mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
state_dir="${FAKE_AGENT_STATE_DIR:-}"
calls=0
if [[ -n "$state_dir" ]]; then
  mkdir -p "$state_dir"
  calls_file="$state_dir/calls"
  [[ -f "$calls_file" ]] && calls="$(cat "$calls_file" 2>/dev/null || printf 0)"
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$calls_file"
fi
if [[ "$calls" -le 1 ]]; then
  # First lens: complete it with a single DONE (--depth 1).
  printf 'DONE\n'
  exit 0
fi
# Second lens onward: emit the Claude user-tier rate-limit signature, exit non-zero.
cat <<'MSG'
You've hit your limit · resets 11:30pm (Europe/Berlin)
MSG
exit 1
SH
chmod +x "$FAKE_BIN/codex"

OUT1="$TMPDIR/out-rl.txt"
RL_STATE="$TMPDIR/rl-state"
PATH="$FAKE_BIN:$PATH" \
FAKE_AGENT_STATE_DIR="$RL_STATE" \
REPOLENS_RATE_LIMIT_MAX_SLEEP=0 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --domain i18n \
    --mode audit \
    --local \
    --depth 1 \
    --yes \
    </dev/null >"$OUT1" 2>&1
RC1=$?

RUN_ID="$(discover_run_id "$OUT1")"
if [[ -n "$RUN_ID" ]]; then
  CREATED_RUN_IDS+=("$RUN_ID")
fi
ATT="$SCRIPT_DIR/logs/$RUN_ID/attempts.json"

assert_eq "run id is discoverable from the rate-limit run output" \
  "set" "$([[ -n "$RUN_ID" ]] && printf 'set' || printf 'missing')"
assert_eq "the rate-limit attempt exits non-zero" \
  "nonzero" "$([[ "$RC1" -ne 0 ]] && printf 'nonzero' || printf 'zero')"

if [[ -z "$RUN_ID" ]]; then
  fail_with "cannot continue without a run id" "no run id parsed from $OUT1"
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  exit 1
fi

COMPLETED_AFTER_1="$(completed_count "$RUN_ID")"

assert_ok "attempts.json is valid JSON after the rate-limit attempt" jq -e . "$ATT"
assert_ok "exactly one attempt is recorded so far" jq -e 'length == 1' "$ATT"
assert_ok "attempt 1 carries the new schema fields" jq -e '
  .[0]
  | has("why_stopped") and has("lenses_completed_total")
    and has("lenses_completed_this_attempt") and has("exit_code")' "$ATT"
assert_ok "attempt 1 why_stopped reflects the rate-limit reason" \
  jq -e '.[0].why_stopped | test("rate-limit")' "$ATT"
assert_ok "attempt 1 status is rate-limit-pending (lens-level rate limit)" \
  jq -e '.[0].status == "rate-limit-pending"' "$ATT"
assert_ok "attempt 1 exit_code matches the process exit code ($RC1)" \
  jq -e --argjson rc "$RC1" '.[0].exit_code == $rc' "$ATT"
assert_ok "attempt 1 lenses_completed_total equals the .completed line count ($COMPLETED_AFTER_1)" \
  jq -e --argjson n "$COMPLETED_AFTER_1" '.[0].lenses_completed_total == $n' "$ATT"
assert_ok "attempt 1 lenses_completed_this_attempt == total on the first attempt ($COMPLETED_AFTER_1)" \
  jq -e --argjson n "$COMPLETED_AFTER_1" '.[0].lenses_completed_this_attempt == $n' "$ATT"

# ---------------------------------------------------------------------------
# Attempt 2 — resume and finish.
# --resume re-runs only the pending (rate-limited) lens; the plain DONE stub
# completes it. The per-attempt delta must reflect ONLY this pass's work, not
# the cumulative total, which is why the count is read as
# (completed-after-2 minus completed-after-1).
# ---------------------------------------------------------------------------
echo ""
echo "Attempt 2: resuming to a finish records a per-attempt delta + a clean exit"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'DONE\n'
exit 0
SH
chmod +x "$FAKE_BIN/codex"

OUT2="$TMPDIR/out-resume.txt"
PATH="$FAKE_BIN:$PATH" \
REPOLENS_RATE_LIMIT_MAX_SLEEP=0 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --resume "$RUN_ID" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --domain i18n \
    --mode audit \
    --local \
    --depth 1 \
    --yes \
    </dev/null >"$OUT2" 2>&1
RC2=$?

COMPLETED_AFTER_2="$(completed_count "$RUN_ID")"
DELTA_2=$(( COMPLETED_AFTER_2 - COMPLETED_AFTER_1 ))
(( DELTA_2 < 0 )) && DELTA_2=0

assert_eq "the resume attempt exits 0" "0" "$RC2"
assert_ok "attempts.json is valid JSON after the resume attempt" jq -e . "$ATT"
assert_ok "two attempts are recorded after the resume" jq -e 'length == 2' "$ATT"
assert_ok "attempt_ids are monotonic: 1 then 2" \
  jq -e '.[0].attempt_id == 1 and .[1].attempt_id == 2' "$ATT"
assert_ok "attempt 2 carries the new schema fields" jq -e '
  .[1]
  | has("why_stopped") and has("lenses_completed_total")
    and has("lenses_completed_this_attempt") and has("exit_code")' "$ATT"
assert_ok "attempt 2 status is finished or finished-empty" \
  jq -e '.[1].status as $s | ["finished","finished-empty"] | index($s) != null' "$ATT"
assert_ok "attempt 2 exit_code matches the process exit code (0)" \
  jq -e --argjson rc "$RC2" '.[1].exit_code == $rc' "$ATT"
assert_ok "attempt 2 lenses_completed_this_attempt is THIS pass's delta ($DELTA_2), not cumulative" \
  jq -e --argjson d "$DELTA_2" '.[1].lenses_completed_this_attempt == $d' "$ATT"
assert_ok "attempt 2 lenses_completed_total equals the cumulative .completed count ($COMPLETED_AFTER_2)" \
  jq -e --argjson n "$COMPLETED_AFTER_2" '.[1].lenses_completed_total == $n' "$ATT"
# The whole point of the per-attempt delta: across the two attempts it sums to
# the cumulative total. When attempt 1 completed >=1 lens this also proves the
# delta is strictly below the cumulative total (i.e. not a cumulative snapshot).
# The `type == "number"` guards keep this RED pre-implementation: jq treats
# `null + null == null` as true, which would otherwise false-green on absent
# fields.
assert_ok "per-attempt deltas sum to the final cumulative total" jq -e '
  (.[0].lenses_completed_this_attempt | type) == "number"
  and (.[1].lenses_completed_this_attempt | type) == "number"
  and (.[1].lenses_completed_total | type) == "number"
  and (.[0].lenses_completed_this_attempt + .[1].lenses_completed_this_attempt)
        == .[1].lenses_completed_total' "$ATT"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
