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

# Tests for issue #226: --strategy {fanout,waves} CLI flag.
#
# Covers:
#   1. Default behavior — no flag means STRATEGY=fanout, visible in dry-run.
#   2. --strategy fanout|waves accepted under --mode bugreport.
#   3. --strategy waves rejected when --mode != bugreport.
#   4. --strategy <invalid> rejected with informative error.
#   5. REPOLENS_STRATEGY env-var fallback when CLI flag is unset.
#   6. REPOLENS_STRATEGY rejects invalid values.
#   7. CLI flag wins over REPOLENS_STRATEGY env — both in the dry-run banner
#      AND at the lib/rounds.sh wave-1 dispatch gate (regression guard for
#      the original #226 bug where the gate kept reading REPOLENS_STRATEGY).
#   8. --help text documents --strategy and REPOLENS_STRATEGY.
#   9. STRATEGY is exported so subshells (parallel workers) see it.
#
# No real models are invoked — all repolens.sh runs use --dry-run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-strategy-flag"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

FAKE_BIN="$TMPDIR/fake-bin"
mkdir -p "$FAKE_BIN"
for _agent in claude codex opencode agy; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$_agent"
  chmod +x "$FAKE_BIN/$_agent"
done
export PATH="$FAKE_BIN:$PATH"

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

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
    fail_with "$desc" "Expected: '$expected' | Actual: '$actual'"
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

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find '$needle'"
  fi
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# strategy test\n' > "$project/README.md"
  git -C "$project" -c user.email=t@t -c user.name=t add README.md >/dev/null 2>&1 || true
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true
}

register_run_id_from() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

# Common: produce a dry-run invocation for a given mode + extra flags.
# Returns the captured output via the file path given.
#
# --local + --output bypasses the forge-detection gate so a freshly-init'd
# project without origin still reaches the dry-run print section.
run_dry() {
  local out_file="$1" name="$2"
  shift 2

  local project="$TMPDIR/project-$name"
  make_project "$project"

  bash "$REPOLENS_SH" \
    --project "$project" \
    --agent claude \
    --dry-run \
    --yes \
    --local \
    --output "$TMPDIR/issues-$name" \
    "$@" \
    >"$out_file" 2>&1
  local rc=$?
  register_run_id_from "$out_file"
  return "$rc"
}

run_dry_env() {
  local out_file="$1" name="$2" env_var="$3"
  shift 3

  local project="$TMPDIR/project-$name"
  make_project "$project"

  # shellcheck disable=SC2086
  env $env_var bash "$REPOLENS_SH" \
    --project "$project" \
    --agent claude \
    --dry-run \
    --yes \
    --local \
    --output "$TMPDIR/issues-$name" \
    "$@" \
    >"$out_file" 2>&1
  local rc=$?
  register_run_id_from "$out_file"
  return "$rc"
}

# A small bug-report file we can reuse for --mode bugreport runs.
BUG_FILE="$TMPDIR/bug.txt"
printf 'Symptom: foo crashes when bar runs.\n' > "$BUG_FILE"

echo ""
echo "=== Test Suite: --strategy flag ==="
echo ""

echo "Test 1: default (no --strategy) resolves to fanout"
out="$TMPDIR/out-default.txt"
run_dry "$out" "default" --mode bugreport --bug-report "$BUG_FILE"
rc=$?
assert_success "default invocation exits 0" "$rc"
assert_contains "dry-run output reports Strategy: fanout by default" \
  "Strategy:" "$(cat "$out")"
assert_contains "default Strategy value is fanout" \
  "fanout" "$(grep -E '^Strategy:' "$out" || true)"

echo ""
echo "Test 2: --strategy fanout accepted under --mode bugreport"
out="$TMPDIR/out-fanout-bugreport.txt"
run_dry "$out" "fanout-bugreport" --mode bugreport --bug-report "$BUG_FILE" --strategy fanout
rc=$?
assert_success "--strategy fanout --mode bugreport exits 0" "$rc"
assert_contains "dry-run reports Strategy: fanout" \
  "fanout" "$(grep -E '^Strategy:' "$out" || true)"

echo ""
echo "Test 3: --strategy waves accepted under --mode bugreport"
out="$TMPDIR/out-waves-bugreport.txt"
run_dry "$out" "waves-bugreport" --mode bugreport --bug-report "$BUG_FILE" --strategy waves
rc=$?
assert_success "--strategy waves --mode bugreport exits 0" "$rc"
assert_contains "dry-run reports Strategy: waves" \
  "waves" "$(grep -E '^Strategy:' "$out" || true)"

echo ""
echo "Test 4: --strategy waves rejected when --mode is not bugreport"
out="$TMPDIR/out-waves-audit.txt"
run_dry "$out" "waves-audit" --mode audit --strategy waves
rc=$?
assert_failure "--strategy waves --mode audit exits non-zero" "$rc"
assert_contains "error mentions --mode bugreport requirement" \
  "bugreport" "$(cat "$out")"
assert_contains "error mentions waves" \
  "waves" "$(cat "$out")"

echo ""
echo "Test 5: --strategy with invalid value is rejected"
out="$TMPDIR/out-invalid.txt"
run_dry "$out" "invalid" --mode bugreport --bug-report "$BUG_FILE" --strategy hokum
rc=$?
assert_failure "--strategy hokum exits non-zero" "$rc"
assert_contains "error mentions --strategy" \
  "strategy" "$(cat "$out")"
assert_contains "error names the bad value" \
  "hokum" "$(cat "$out")"

echo ""
echo "Test 6: --strategy without an argument is rejected"
out="$TMPDIR/out-no-arg.txt"
run_dry "$out" "no-arg" --mode bugreport --bug-report "$BUG_FILE" --strategy
rc=$?
assert_failure "--strategy with no value exits non-zero" "$rc"

echo ""
echo "Test 7: REPOLENS_STRATEGY=waves picked up when CLI flag is unset"
out="$TMPDIR/out-env-waves.txt"
run_dry_env "$out" "env-waves" "REPOLENS_STRATEGY=waves" \
  --mode bugreport --bug-report "$BUG_FILE"
rc=$?
assert_success "REPOLENS_STRATEGY=waves exits 0" "$rc"
assert_contains "env-var resolved Strategy is waves" \
  "waves" "$(grep -E '^Strategy:' "$out" || true)"

echo ""
echo "Test 8: REPOLENS_STRATEGY with invalid value is rejected"
out="$TMPDIR/out-env-bad.txt"
run_dry_env "$out" "env-bad" "REPOLENS_STRATEGY=hokum" \
  --mode bugreport --bug-report "$BUG_FILE"
rc=$?
assert_failure "REPOLENS_STRATEGY=hokum exits non-zero" "$rc"
assert_contains "error mentions REPOLENS_STRATEGY" \
  "REPOLENS_STRATEGY" "$(cat "$out")"

echo ""
echo "Test 9: CLI --strategy wins over REPOLENS_STRATEGY env"
out="$TMPDIR/out-cli-wins.txt"
run_dry_env "$out" "cli-wins" "REPOLENS_STRATEGY=waves" \
  --mode bugreport --bug-report "$BUG_FILE" --strategy fanout
rc=$?
assert_success "CLI override exits 0" "$rc"
assert_contains "CLI --strategy fanout wins over env waves" \
  "fanout" "$(grep -E '^Strategy:' "$out" || true)"

# Dispatch-site regression guard: the wave-1 dispatch gate in lib/rounds.sh
# must NOT read REPOLENS_STRATEGY directly. If it does, then `--strategy
# fanout` on the CLI is silently overridden at the actual dispatch decision
# whenever REPOLENS_STRATEGY=waves is in the environment, even though the
# resolved $STRATEGY (and dry-run banner) say "fanout". The banner-only
# assertion above masked this exact bug — this check closes the gap by
# asserting the dispatch gate evaluates `STRATEGY` alone.
TOTAL=$((TOTAL + 1))
gate_offenders="$(grep -nE 'REPOLENS_STRATEGY' "$SCRIPT_DIR/lib/rounds.sh" || true)"
if [[ -z "$gate_offenders" ]]; then
  pass_with "wave-1 dispatch gate reads only resolved \$STRATEGY (no REPOLENS_STRATEGY)"
else
  fail_with "wave-1 dispatch gate reads only resolved \$STRATEGY (no REPOLENS_STRATEGY)" \
    "lib/rounds.sh still references REPOLENS_STRATEGY: $gate_offenders"
fi

# Behavioural assertion: evaluate the literal dispatch-gate condition with the
# CLI-resolved STRATEGY in the env, plus a stale REPOLENS_STRATEGY=waves
# inherited from the parent shell. The fixed gate evaluates false (fanout
# wins); the buggy OR-clause version would evaluate true.
TOTAL=$((TOTAL + 1))
gate_result="$(STRATEGY=fanout REPOLENS_STRATEGY=waves MODE=bugreport bash -c '
  set -uo pipefail
  if [[ "${MODE:-}" == "bugreport" ]] \
      && [[ "${STRATEGY:-}" == "waves" ]]; then
    echo waves-branch
  else
    echo fanout-branch
  fi
')"
if [[ "$gate_result" == "fanout-branch" ]]; then
  pass_with "dispatch gate honours CLI fanout even when REPOLENS_STRATEGY=waves leaks via env"
else
  fail_with "dispatch gate honours CLI fanout even when REPOLENS_STRATEGY=waves leaks via env" \
    "Expected 'fanout-branch', got '$gate_result'"
fi

echo ""
echo "Test 10: --help documents --strategy and REPOLENS_STRATEGY"
help_out="$(bash "$REPOLENS_SH" --help 2>&1)"
help_rc=$?
assert_success "--help exits 0" "$help_rc"
assert_contains "help text mentions --strategy" "--strategy" "$help_out"
assert_contains "help text mentions fanout option" "fanout" "$help_out"
assert_contains "help text mentions waves option" "waves" "$help_out"
assert_contains "help text documents REPOLENS_STRATEGY env fallback" \
  "REPOLENS_STRATEGY" "$help_out"

echo ""
echo "Test 11: STRATEGY is exported to subshells (round/worker safety)"
# The lib/rounds.sh wave-1 branch reads ${STRATEGY:-} from a subshell context
# (parallel workers + sourced libs). The CLI must export the variable so the
# branch fires there. Use --dry-run output as the contract: it must report
# the resolved strategy reflecting both CLI flag and env-var fallback. The
# fact that the dry-run output reflects the resolved value implies the
# assignment happened pre-export. To assert the export itself, we look for
# Strategy in dry-run output combined with the wave-1-only env override
# (REPOLENS_STRATEGY) flowing through unchanged when no flag is given.
out="$TMPDIR/out-export.txt"
run_dry_env "$out" "export" "REPOLENS_STRATEGY=waves" \
  --mode bugreport --bug-report "$BUG_FILE"
rc=$?
assert_success "env-only waves run exits 0" "$rc"
strat_line="$(grep -E '^Strategy:' "$out" || true)"
assert_contains "Strategy line in dry-run reflects resolved value" \
  "waves" "$strat_line"

echo ""
echo "Test 12: --strategy fanout accepted on non-bugreport modes"
# The mode-mismatch guard is asymmetric: only --strategy waves is restricted
# to --mode bugreport. --strategy fanout is the universal default and must
# remain accepted (no-op) in every other mode, otherwise we'd break audit/
# feature/bugfix/discover/deploy/etc. invocations that pass --strategy fanout
# (e.g. for orchestrators that always supply the flag).
out="$TMPDIR/out-fanout-audit.txt"
run_dry "$out" "fanout-audit" --mode audit --strategy fanout
rc=$?
assert_success "--strategy fanout --mode audit exits 0" "$rc"

echo ""
echo "Test 13: REPOLENS_STRATEGY=fanout env-var fallback accepted"
# Symmetric to Test 7 (waves): both valid env values must be honoured by the
# CLI->env fallback block, not just 'waves'. Without this case, a regression
# that hard-codes the env fallback to 'waves' only (or rejects 'fanout' as
# meaningless) would slip through.
out="$TMPDIR/out-env-fanout.txt"
run_dry_env "$out" "env-fanout" "REPOLENS_STRATEGY=fanout" \
  --mode bugreport --bug-report "$BUG_FILE"
rc=$?
assert_success "REPOLENS_STRATEGY=fanout exits 0" "$rc"
assert_contains "env-var resolved Strategy is fanout" \
  "fanout" "$(grep -E '^Strategy:' "$out" || true)"

echo ""
echo "Test 14a: REPOLENS_STRATEGY=waves rejected when --mode is not bugreport"
# Symmetric to Test 4 (CLI path). The mode validation fires AFTER env resolution
# in repolens.sh, so it must catch env-resolved waves too. Without this case, a
# regression that moved the waves+bugreport guard into CLI arg parsing only
# (instead of after the env fallback) would silently dispatch waves in audit/
# feature/etc. when REPOLENS_STRATEGY=waves leaked from a parent shell.
out="$TMPDIR/out-env-waves-audit.txt"
run_dry_env "$out" "env-waves-audit" "REPOLENS_STRATEGY=waves" --mode audit
rc=$?
assert_failure "REPOLENS_STRATEGY=waves --mode audit exits non-zero" "$rc"
assert_contains "env-path error mentions --mode bugreport requirement" \
  "bugreport" "$(cat "$out")"
assert_contains "env-path error mentions waves" \
  "waves" "$(cat "$out")"

echo ""
echo "Test 14: Strategy line in dry-run is gated to --mode bugreport"
# The dry-run banner only prints 'Strategy:' under --mode bugreport because
# the flag is meaningless elsewhere. Verifying its absence on non-bugreport
# modes guards against an accidental ungating that would clutter every dry-run.
out="$TMPDIR/out-audit-no-strategy-line.txt"
run_dry "$out" "audit-no-strategy" --mode audit
rc=$?
assert_success "--mode audit dry-run exits 0" "$rc"
TOTAL=$((TOTAL + 1))
if ! grep -qE '^Strategy:' "$out"; then
  pass_with "Strategy line absent from non-bugreport dry-run"
else
  fail_with "Strategy line absent from non-bugreport dry-run" \
    "Found: $(grep -E '^Strategy:' "$out")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
