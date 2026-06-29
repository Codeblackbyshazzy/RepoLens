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

# End-to-end regression test for issue #378: the three core resume guarantees,
# locked in through the real `repolens.sh --resume` CLI path (no real model,
# nothing filed):
#
#   (1) `--resume <id>` reuses the SAME logs/<id>/ dir — no sibling is minted.
#   (2) lenses listed in logs/<id>/.completed are skipped on resume (the
#       seeded lens is preserved — .completed is touched, not truncated).
#   (3) a `--focus <id>` re-run under `--resume <id>` APPENDS the focused lens
#       to that run's .completed instead of starting a fresh equal dir.
#
# Then a second resume that `--focus`es the already-seeded lens must be skipped
# (round-level "Skipping completed round" or per-lens "already completed").
#
# Existing resume tests cover the inner round helper (test_rounds_resume.sh) or
# the status snapshot (test_status_json_resume.sh) but none drive the top-level
# CLI through run-id resolution, LOG_BASE derivation, .completed semantics, and
# --focus list narrowing. A refactor of repolens.sh's run-id/LOG_BASE/.completed
# block could silently regress the user-reported "can't continue" surface; this
# test guards it.
#
# Uses tests/mock-agent.sh via a PATH-shimmed fake `codex` (and a fake `gh`),
# in GitHub mode (--forge gh) so the agent files nothing: the mock renders no
# local output dir and REPOLENS_MOCK_WRITE_FINDINGS_WITHOUT_LOCAL is left unset,
# so it emits DONE and writes/files nothing. Single round, --depth 1 streak →
# runs in ~1-2s.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
KEEP_ARTIFACTS=0

TMP_PARENT="$SCRIPT_DIR/logs/test-resume-focus-merge"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

cleanup() {
  local run_id
  if (( KEEP_ARTIFACTS == 0 )); then
    rm -rf "$TMPDIR"
    for run_id in "${CREATED_RUN_IDS[@]:-}"; do
      [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
    done
    rmdir "$TMP_PARENT" 2>/dev/null || true
  else
    printf 'Preserved test artifacts: %s\n' "$TMPDIR"
    for run_id in "${CREATED_RUN_IDS[@]:-}"; do
      [[ -n "$run_id" ]] && printf 'Preserved RepoLens log dir: %s\n' "$SCRIPT_DIR/logs/$run_id"
    done
  fi
}
trap cleanup EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find: $needle"
  fi
}

assert_file_contains_line() {
  local desc="$1" line="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qxF "$line" "$file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $file to contain the exact line: $line"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

echo "=== resume reuses dir, skips completed, --focus merges (issue #378) ==="

# ---------------------------------------------------------------------------
# Setup: throwaway git project + PATH-shimmed fake codex/gh.
# ---------------------------------------------------------------------------
PROJECT_DIR="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
MOCK_LOG1="$TMPDIR/mock-agent-1.log"
MOCK_LOG2="$TMPDIR/mock-agent-2.log"
GH_LOG="$TMPDIR/gh.log"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" remote add origin https://github.com/example/repo.git
printf '# RepoLens issue 378 fixture\nA stable anchor for the resume test.\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" \
  -c user.name='RepoLens Test' \
  -c user.email='repolens@example.invalid' \
  add README.md
git -C "$PROJECT_DIR" \
  -c user.name='RepoLens Test' \
  -c user.email='repolens@example.invalid' \
  commit -q -m 'fixture'

cat > "$FAKE_BIN/codex" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/tests/mock-agent.sh" "\$@"
EOF
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_GH_LOG:-/dev/null}"
case "$1 $2" in
  "auth status") exit 0 ;;
  "label list") printf '[]\n'; exit 0 ;;
  "label create") exit 0 ;;
  "issue list") printf '[]\n'; exit 0 ;;
  "issue create") printf 'https://github.com/example/repo/issues/3780\n'; exit 0 ;;
  "issue view") printf '{"title":"mock"}\n'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/gh" "$SCRIPT_DIR/tests/mock-agent.sh"

# Seed an interrupted run: a logs/<id>/ dir whose .completed already records
# one finished lens. LOG_BASE is hard-wired to $SCRIPT_DIR/logs/<id> with no
# env override, so the seeded dir must live under the real repo logs/.
RUN_ID="20260101T000000Z-resumefocus-$$"
CREATED_RUN_IDS+=("$RUN_ID")
LOG_BASE="$SCRIPT_DIR/logs/$RUN_ID"
SEED_LENS="security/injection"
FOCUS_LENS_ID="xss-csrf"
FOCUS_LENS="security/$FOCUS_LENS_ID"
mkdir -p "$LOG_BASE"
printf '%s\n' "$SEED_LENS" > "$LOG_BASE/.completed"

# ---------------------------------------------------------------------------
# Resume #1: focus a DIFFERENT lens than the seeded one.
# ---------------------------------------------------------------------------
run1_out="$TMPDIR/resume1.out"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_FINDINGS=0 \
  REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG1" \
  REPOLENS_FAKE_GH_LOG="$GH_LOG" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --forge gh \
    --mode audit \
    --focus "$FOCUS_LENS_ID" \
    --resume "$RUN_ID" \
    --rounds 1 \
    --depth 1 \
    --yes \
    >"$run1_out" 2>&1
run1_rc=$?

assert_eq "resume #1 exits successfully" "0" "$run1_rc"

# (1) dir reuse — the resume operated under the SEEDED run id, not a freshly
# minted one. A fresh (non-resume) run mints RUN_ID="<timestamp>-<hex>"; a resume
# reuses the id verbatim. repolens logs "RepoLens run <id> complete" using the
# same RUN_ID that derives LOG_BASE, so an id match is airtight proof that the
# run wrote into the seeded dir and minted no sibling. This is robust to other
# repolens runs that may concurrently create unrelated dirs under logs/ (a global
# logs/ snapshot would be racy on a shared host).
logged_run_id="$(sed -n 's/.*RepoLens run \([^ ]*\) complete.*/\1/p' "$run1_out" | tail -1)"
assert_eq "resume #1 reused the seeded run id (no sibling dir minted)" \
  "$RUN_ID" "$logged_run_id"
assert_eq "resumed logs/<id> dir still present after resume #1" \
  "present" "$([[ -d "$LOG_BASE" ]] && printf 'present' || printf 'missing')"

# (2) the seeded lens is NOT re-run: with --focus narrowing LENS_LIST to a
# single lens, the mock agent is invoked exactly once for the focused lens.
# If the seeded lens had been re-run there would be two lens invocations.
# (grep -c prints the count AND exits non-zero on zero matches, so swallow the
# status with `|| true` and default an empty/missing-file result to 0.)
lens_invocations="$(grep -c '^lens$' "$MOCK_LOG1" 2>/dev/null || true)"
lens_invocations="${lens_invocations:-0}"
assert_eq "resume #1 ran exactly one lens (seeded lens not re-run)" \
  "1" "$lens_invocations"
assert_file_contains_line "seeded lens preserved in .completed (touch, not truncate)" \
  "$SEED_LENS" "$LOG_BASE/.completed"

# (3) --focus merge — the focused lens is appended next to the seeded one.
assert_file_contains_line "focused lens appended to the same .completed" \
  "$FOCUS_LENS" "$LOG_BASE/.completed"

# Nothing was filed: the fake gh never saw an `issue create`.
gh_creates="$(grep -c 'issue create' "$GH_LOG" 2>/dev/null || true)"
gh_creates="${gh_creates:-0}"
assert_eq "no issue was filed during resume #1" "0" "$gh_creates"

# ---------------------------------------------------------------------------
# Resume #2: focus the ALREADY-SEEDED lens — must be skipped.
# ---------------------------------------------------------------------------
run2_out="$TMPDIR/resume2.out"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_AGENT_TIMEOUT=10 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  REPOLENS_MOCK_AGENT_FINDINGS=0 \
  REPOLENS_MOCK_AGENT_LOG="$MOCK_LOG2" \
  REPOLENS_FAKE_GH_LOG="$GH_LOG" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --forge gh \
    --mode audit \
    --focus injection \
    --resume "$RUN_ID" \
    --rounds 1 \
    --depth 1 \
    --yes \
    >"$run2_out" 2>&1
run2_rc=$?

assert_eq "resume #2 exits successfully" "0" "$run2_rc"

TOTAL=$((TOTAL + 1))
if grep -Eq 'Skipping completed round|already completed' "$run2_out"; then
  pass_with "resume #2 skips the already-completed seeded lens (round or per-lens skip logged)"
else
  fail_with "resume #2 skips the already-completed seeded lens (round or per-lens skip logged)" \
    "Neither 'Skipping completed round' nor 'already completed' appeared in resume #2 output"
fi

# The seeded lens is not re-executed on the second resume.
lens_invocations2="$(grep -c '^lens$' "$MOCK_LOG2" 2>/dev/null || true)"
lens_invocations2="${lens_invocations2:-0}"
assert_eq "resume #2 ran no lenses (seeded lens skipped, not re-run)" \
  "0" "$lens_invocations2"

finish
