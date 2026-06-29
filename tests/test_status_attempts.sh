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

# Tests for issue #377 — Surface the parent-run + attempts model in
# status/summary (no dir-layout change).
#
# Behavioral contract (from the issue's acceptance criteria):
#   AC#1  status.json carries an `attempts` array derived from
#         logs/<run-id>/attempts.json — a compact projection of
#         { attempt_id, status, why_stopped, lenses_completed_this_attempt }.
#         An ABSENT or CORRUPT attempts.json degrades to `attempts: []` and
#         never aborts the snapshot builder (it is strictly non-fatal, like
#         the rest of `_write_status_snapshot_locked`).
#   AC#2  A run resumed once shows 2 attempts in `repolens.sh status <run-id>`
#         output (the default, non-JSON human render) and in the terminal
#         status.json.
#   AC#3  A single-attempt run prints NO multi-attempt summary note.
#   AC#4  The flat logs/<run-id>/ layout is unchanged; resume reuses the SAME
#         dir, so attempts.json accrues entries [1, 2] in one parent dir.
#
# RED-phase expectation (TDD): the implementation does not exist yet, so
# `_write_status_snapshot_locked` emits no `attempts` field, the human render
# prints no attempts line, and the end-of-run note is never produced. Parts A,
# B and the end-to-end status.json/positive-note checks therefore FAIL until
# the implementation lands. The single-attempt "no note" check (AC#3) is a
# negative-space assertion that holds in both phases; it is paired with the
# positive note check so the `> 1` guard is pinned exactly.
#
# No real models (CLAUDE.md hard rule): Parts A/B call the snapshot builder and
# the human render directly with fabricated files. Part C drives full runs with
# a PATH-shimmed fake `codex` -> tests/mock-agent.sh (deterministic, no agent),
# the same technique as tests/test_attempts_json.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/status.sh
source "$SCRIPT_DIR/lib/status.sh"
trap status_cleanup EXIT

# Silence the builder's non-fatal warnings (it warns + returns 0 on bad input).
log_warn() {
  :
}

echo "=== status.json attempts surfacing (issue #377) ==="
status_require_jq

# seed_run_dir <log_base> — fabricate the minimal file-backed inputs the
# snapshot builder reads (summary.json, heartbeat dir, .completed, .status-lenses)
# so write_status_snapshot succeeds. The caller adds attempts.json separately.
seed_run_dir() {
  local lb="$1"
  mkdir -p "$lb/.heartbeat"
  # The run_id is deliberately free of the substring "attempt" so the human
  # render's "RepoLens run <run_id>" header does not false-match Part B's
  # attempts-line search below.
  cat > "$lb/summary.json" <<'JSON'
{
  "run_id": "rl9z-run",
  "started_at": "2026-06-29T10:00:00Z",
  "totals": { "issues_created": 2 }
}
JSON
  printf '%s\n' "security/xss" "security/ssrf" > "$lb/.status-lenses"
  printf '%s\n' "security/xss" > "$lb/.completed"
}

# run_snapshot <log_base> [state] — call the public builder with the canonical
# 13 positional args (state run_id log_base heartbeat completed summary project
# repo mode agent parallel max_parallel lenses_file).
run_snapshot() {
  local lb="$1" state="${2:-finished}"
  write_status_snapshot \
    "$state" "rl9z-run" "$lb" "$lb/.heartbeat" "$lb/.completed" \
    "$lb/summary.json" "/tmp/project" "owner/repo" "audit" "codex" "false" "1" \
    "$lb/.status-lenses"
}

# ---------------------------------------------------------------------------
# Part A — AC#1: status.json gains an `attempts` array from attempts.json.
# ---------------------------------------------------------------------------

# A1: a 2-entry attempts.json is projected into a compact 2-element array.
echo ""
echo "Part A1: two attempts are surfaced as a compact array"
LB1="$STATUS_TEST_TMPDIR/two-attempts"
seed_run_dir "$LB1"
cat > "$LB1/attempts.json" <<'JSON'
[
  {
    "attempt_id": 1,
    "started_at": "2026-06-29T10:00:00Z",
    "finished_at": "2026-06-29T10:05:00Z",
    "status": "interrupted",
    "why_stopped": "rate-limited",
    "lenses_completed_this_attempt": 12,
    "lenses_completed_total": 12,
    "exit_code": 3
  },
  {
    "attempt_id": 2,
    "started_at": "2026-06-29T10:10:00Z",
    "finished_at": "2026-06-29T10:20:00Z",
    "status": "finished",
    "why_stopped": "",
    "lenses_completed_this_attempt": 9,
    "lenses_completed_total": 21,
    "exit_code": 0
  }
]
JSON
if run_snapshot "$LB1"; then
  assert_eq "snapshot write succeeds with a 2-entry attempts.json" "0" "0"
else
  assert_eq "snapshot write succeeds with a 2-entry attempts.json" "0" "1"
fi
assert_jq "status.json remains valid JSON" "$LB1/status.json" '.'
assert_jq "attempts array has both entries" "$LB1/status.json" \
  '.attempts | length == 2'
assert_jq "each attempt carries the compact projection fields" "$LB1/status.json" \
  '.attempts[0]
   | has("attempt_id") and has("status")
     and has("why_stopped") and has("lenses_completed_this_attempt")'
assert_jq "attempt 1 values are projected verbatim from attempts.json" "$LB1/status.json" \
  '.attempts[0].attempt_id == 1
   and .attempts[0].status == "interrupted"
   and .attempts[0].why_stopped == "rate-limited"
   and .attempts[0].lenses_completed_this_attempt == 12'
assert_jq "latest attempt status is surfaced" "$LB1/status.json" \
  '.attempts[1].status == "finished"'

# A2: an absent attempts.json degrades to [] without error (AC#1).
echo ""
echo "Part A2: an absent attempts.json yields attempts: []"
LB2="$STATUS_TEST_TMPDIR/no-attempts"
seed_run_dir "$LB2"
if run_snapshot "$LB2"; then
  assert_eq "snapshot write succeeds when attempts.json is absent" "0" "0"
else
  assert_eq "snapshot write succeeds when attempts.json is absent" "0" "1"
fi
assert_jq "absent attempts.json -> attempts: []" "$LB2/status.json" \
  '.attempts == []'

# A3: a corrupt / non-array attempts.json degrades to [] (non-fatal hardening).
echo ""
echo "Part A3: a corrupt or non-array attempts.json yields attempts: []"
LB3="$STATUS_TEST_TMPDIR/corrupt-attempts"
seed_run_dir "$LB3"
printf 'this is not json\n' > "$LB3/attempts.json"
if run_snapshot "$LB3"; then
  assert_eq "snapshot write succeeds with a corrupt attempts.json (non-fatal)" "0" "0"
else
  assert_eq "snapshot write succeeds with a corrupt attempts.json (non-fatal)" "0" "1"
fi
assert_jq "garbage attempts.json -> attempts: []" "$LB3/status.json" \
  '.attempts == []'

LB4="$STATUS_TEST_TMPDIR/object-attempts"
seed_run_dir "$LB4"
printf '%s\n' '{"not": "an array"}' > "$LB4/attempts.json"
run_snapshot "$LB4" >/dev/null 2>&1
assert_jq "non-array attempts.json -> attempts: []" "$LB4/status.json" \
  '.attempts == []'

# ---------------------------------------------------------------------------
# Part B — AC#2: the default human render surfaces the attempts count, so
# `repolens.sh status <run-id>` (no --json) shows 2 attempts.
# ---------------------------------------------------------------------------
echo ""
echo "Part B: the human render shows the attempts count"
RENDER_OUT="$(status_render_human "$LB1/status.json" 120 false 2>/dev/null || true)"
assert_contains "human render surfaces an attempts line" "attempt" "$RENDER_OUT"
ATT_LINE="$(printf '%s\n' "$RENDER_OUT" | grep -i 'attempt' | head -1)"
assert_contains "the attempts line shows the count of 2" "2" "$ATT_LINE"
# The render emits `attempts:  N  (latest: <status>)` — pin the latest-status
# content too, not just the count. LB1's last attempt is "finished"; without
# this the `(latest: %s)` half of the printf could regress (wrong source, or
# dropped) and Part B would still pass on the bare count.
assert_contains "the attempts line surfaces the latest attempt status" \
  "finished" "$ATT_LINE"

# B2: a single-attempt status.json prints NO attempts line. This pins the `> 1`
# guard in status_render_human — the render symmetric of the AC#3 end-of-run
# "no note" check, which Part C only exercises on the echo path. A regression to
# `>= 1` would leak a spurious `attempts: 1` line that the count/latest asserts
# above (which use the 2-attempt fixture) cannot catch.
echo ""
echo "Part B2: a single-attempt run prints NO attempts line in the human render"
LB_ONE="$STATUS_TEST_TMPDIR/one-attempt"
seed_run_dir "$LB_ONE"
cat > "$LB_ONE/attempts.json" <<'JSON'
[
  {
    "attempt_id": 1,
    "started_at": "2026-06-29T10:00:00Z",
    "finished_at": "2026-06-29T10:05:00Z",
    "status": "finished",
    "why_stopped": "",
    "lenses_completed_this_attempt": 21,
    "lenses_completed_total": 21,
    "exit_code": 0
  }
]
JSON
run_snapshot "$LB_ONE" >/dev/null 2>&1
assert_jq "single-attempt status.json records exactly 1 attempt" "$LB_ONE/status.json" \
  '.attempts | length == 1'
RENDER_ONE="$(status_render_human "$LB_ONE/status.json" 120 false 2>/dev/null || true)"
# Sanity: the render ran far enough to reach where the attempts line would print,
# so its absence below is meaningful (not an empty/aborted render).
assert_contains "single-attempt render still emits the progress line (sanity)" \
  "progress:" "$RENDER_ONE"
if printf '%s\n' "$RENDER_ONE" | grep -Eq '^[[:space:]]*attempts:'; then
  ONE_ATT_LINE="present"
else
  ONE_ATT_LINE="absent"
fi
assert_eq "single-attempt human render prints NO attempts line (> 1 guard)" \
  "absent" "$ONE_ATT_LINE"

# ---------------------------------------------------------------------------
# Part C — AC#2/#3/#4: end-of-run multi-attempt note + same-dir resume, driven
# through full mock runs (deterministic, no real model).
# ---------------------------------------------------------------------------
echo ""
echo "Part C: end-of-run note + same-dir resume (full mock runs)"
FAKE_BIN="$STATUS_TEST_TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/tests/mock-agent.sh" "\$@"
EOF
chmod +x "$FAKE_BIN/codex"

PROJ_C="$STATUS_TEST_TMPDIR/proj-c"
mkdir -p "$PROJ_C"
git -C "$PROJ_C" init -q
printf '# attempts fixture\n' > "$PROJ_C/README.md"
git -C "$PROJ_C" add README.md
git -C "$PROJ_C" \
  -c user.name='RepoLens Test' -c user.email='repolens@example.invalid' \
  commit -q -m fixture

discover_run_id() {
  grep -oE 'RepoLens run [^ ]+ starting' "$1" 2>/dev/null | head -1 | awk '{print $3}'
}

# Attempt 1 — a fresh full run (single attempt).
OUT_C1="$STATUS_TEST_TMPDIR/out-c1.txt"
env -u REPOLENS_ROUNDS -u REPOLENS_MAX_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJ_C" \
    --agent codex \
    --local \
    --focus injection \
    --depth 1 \
    --output "$STATUS_TEST_TMPDIR/issues-c" \
    --yes \
    </dev/null >"$OUT_C1" 2>&1 || true
RID_C="$(discover_run_id "$OUT_C1")"
status_register_run_id "$RID_C"

if [[ -z "$RID_C" ]]; then
  assert_eq "a run id is discoverable from the fresh full run" "set" "missing"
else
  # Sanity: the run reached the end-of-run summary block, so a note-absence
  # below is meaningful (the note location WAS evaluated).
  assert_contains "fresh run reaches the end-of-run summary block" \
    "RepoLens Run Summary" "$(cat "$OUT_C1")"
  # AC#3: a single-attempt run prints NO multi-attempt note.
  if grep -q 'This run took' "$OUT_C1"; then NOTE_C1="present"; else NOTE_C1="absent"; fi
  assert_eq "single-attempt run prints NO multi-attempt note (AC#3)" "absent" "$NOTE_C1"
  # AC#1 end-to-end: the terminal status.json records exactly one attempt.
  assert_jq "terminal status.json records 1 attempt after a fresh run" \
    "$SCRIPT_DIR/logs/$RID_C/status.json" '.attempts | length == 1'

  # Attempt 2 — resume the SAME run; it appends a second attempt.
  OUT_C2="$STATUS_TEST_TMPDIR/out-c2.txt"
  env -u REPOLENS_ROUNDS -u REPOLENS_MAX_ROUNDS -u DONE_STREAK_REQUIRED \
    PATH="$FAKE_BIN:$PATH" \
    REPOLENS_AGENT_TIMEOUT=10 \
    REPOLENS_AGENT_KILL_GRACE=1 \
    bash "$SCRIPT_DIR/repolens.sh" \
      --resume "$RID_C" \
      --project "$PROJ_C" \
      --agent codex \
      --local \
      --focus injection \
      --depth 1 \
      --output "$STATUS_TEST_TMPDIR/issues-c" \
      --yes \
      </dev/null >"$OUT_C2" 2>&1 || true

  # AC#4: resume reuses the SAME dir, so attempts.json accrues [1, 2] in one dir.
  assert_jq "resume reuses the same dir; attempts.json has 2 entries" \
    "$SCRIPT_DIR/logs/$RID_C/attempts.json" 'length == 2'
  # AC#2 end-to-end: the terminal status.json now shows 2 attempts.
  assert_jq "terminal status.json shows 2 attempts after one resume (AC#2)" \
    "$SCRIPT_DIR/logs/$RID_C/status.json" '.attempts | length == 2'
  # Positive note: a multi-attempt run prints the count + the continuation pointer.
  if grep -Eq 'This run took 2 attempts.*attempts\.json' "$OUT_C2"; then
    NOTE_C2="present"
  else
    NOTE_C2="absent"
  fi
  assert_eq "resumed (2-attempt) run prints the multi-attempt note with pointer" \
    "present" "$NOTE_C2"
  # The issue's note format is `This run took N attempts (latest: <status>). …`.
  # The regex above only pins the count + the attempts.json pointer; assert the
  # `(latest:` token too so the echo's latest-status half cannot silently drop.
  assert_contains "the multi-attempt note also surfaces the latest-attempt token" \
    "(latest:" "$(cat "$OUT_C2")"
fi

status_finish
