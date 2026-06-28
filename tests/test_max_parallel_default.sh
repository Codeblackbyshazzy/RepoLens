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

# Tests for issue #367 — Reassess default `--max-parallel 8`; nproc-aware default.
#
# Decision recorded in the issue/research: when the user does NOT pass
# --max-parallel, the resolved default becomes nproc-aware:
#
#     resolved_default = clamp(detected_cores, FLOOR=8, CAP=32)
#
#   - FLOOR=8 keeps today's default as a floor, so small/CI hosts never regress.
#   - CAP=32 bounds host-RAM blow-up and provider rate-limit exposure.
#   - An explicit `--max-parallel N` is ALWAYS authoritative — auto-default only
#     fills the unset case and never re-clamps or overrides an explicit value.
#   - Determinism under test: the detected core count is pinned BEFORE the clamp
#     via the REPOLENS_NPROC env override, so tests can assert floor/mid/cap.
#
# Acceptance criteria exercised here:
#   AC2: Explicit `--max-parallel N` always wins over the auto-default.
#   AC3: The default is deterministic under test (REPOLENS_NPROC pins cores).
#   AC4: Usage / env help reflects the new nproc-aware default.
#   (Secondary, in-scope per research §6: an invalid `--max-parallel` value is
#    rejected with a clear error instead of silently misbehaving.)
#
# These are BEHAVIORAL tests driven through `repolens.sh --dry-run`, which exits
# before any agent runs. The resolved concurrency is observed through the
# dry-run preview's wall-clock line:
#     "Estimated wall-clock: ~<dur> at --max-parallel <N>  (rough; ...)."
# That line prints the resolved MAX_PARALLEL even for a sequential dry-run, so it
# is the stable public surface for asserting the resolution rule WITHOUT binding
# to any internal helper name. NO real models are invoked — a fake `codex` on
# PATH is the only "agent", and every run uses --dry-run so it never executes.
#
# Determinism: REPOLENS_NPROC pins the detected core count for each run; the
# host's real nproc never leaks in (it is scrubbed from the run environment).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$SCRIPT_DIR/repolens.sh"
ROUNDS_BASELINE_TEST="$SCRIPT_DIR/tests/test_rounds_default_no_regression.sh"

TMP_PARENT="$SCRIPT_DIR/logs/test-max-parallel-default"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()
BUG_FILE="$TMPDIR/bug-report.md"
printf 'Max-parallel default fixture bug report — placeholder text.\n' > "$BUG_FILE"

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
LAST_OUTPUT_FILE=""
LAST_RC=0

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

assert_ne() {
  local desc="$1" not_expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$not_expected" != "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected value to differ from: $not_expected"
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

# Extended-regex match against a file's contents.
assert_file_matches() {
  local desc="$1" file="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if grep -Eq "$pattern" "$file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected $file to match: $pattern"
  fi
}

make_fake_codex() {
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'DONE\n'
EOF
  chmod +x "$FAKE_BIN/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  # Enough source bytes so the cost block (and thus the TOTAL_LENSES>0 path the
  # wall-clock line shares) is reached in dry-run.
  local i
  for i in $(seq 1 20); do
    printf 'line %d of seed source — keep the repo above the 1k-token threshold\n' "$i" \
      >> "$project/src.txt"
  done
  printf '# max-parallel default fixture\n' > "$project/README.md"
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

# Extract the resolved concurrency from the dry-run wall-clock line, e.g.
#   "Estimated wall-clock: ~4m 30s at --max-parallel 16  (rough; ...)"  -> 16
# Prints the empty string when the line is absent (e.g. a run that died on a
# validation error before the preview).
resolved_max_parallel() {
  printf '%s\n' "$1" | grep -oE 'at --max-parallel [0-9]+' | head -1 | awk '{print $3}'
}

# run_dryrun NAME [ENV=VAL ...] -- [repolens-args ...]
#
# ENV=VAL tokens before `--` are injected into repolens' environment for this
# run only. Tokens after `--` are forwarded to repolens.sh. Output (stdout AND
# stderr — a validation die() goes to stderr) is captured merged so assertions
# see both streams. REPOLENS_NPROC and the rounds knobs are scrubbed from the
# calling shell first, so the host's real core count never leaks into a run and
# only the per-test pin is in effect.
run_dryrun() {
  local name="$1"
  shift

  local -a env_extras=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_extras+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift

  local project="$TMPDIR/proj-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/out-$name.txt"

  env -u REPOLENS_NPROC -u REPOLENS_ROUNDS -u REPOLENS_MAX_ROUNDS \
      -u DONE_STREAK_REQUIRED \
    PATH="$FAKE_BIN:$PATH" \
    "${env_extras[@]}" \
    bash "$REPO" \
      --project "$project" \
      --agent codex \
      --mode bugreport \
      --bug-report "$BUG_FILE" \
      --local \
      --output "$TMPDIR/issues-$name" \
      --dry-run --yes \
      "$@" </dev/null >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
  register_created_run_id
}

echo ""
echo "=== Test Suite: nproc-aware --max-parallel default (issue #367) ==="
echo ""

make_fake_codex

# ---------------------------------------------------------------------------
# AC3 + clamp FLOOR — a sub-floor core count resolves to the floor (8), so a
# 1-4 core CI box never drops below today's default. (Regression lock: the
# floor equals today's static default, so this also pins "no small-host
# regression".)
# ---------------------------------------------------------------------------
echo "Test 1: REPOLENS_NPROC below the floor resolves to --max-parallel 8 (floor)"
run_dryrun "floor" REPOLENS_NPROC=2 --
assert_eq "sub-floor dry-run exits 0" "0" "$LAST_RC"
assert_eq "REPOLENS_NPROC=2 clamps up to the floor 8" \
          "8" "$(resolved_max_parallel "$(last_output)")"

# ---------------------------------------------------------------------------
# AC3 — REPOLENS_NPROC is the deterministic pin: an exact-floor value yields 8
# verbatim. This is the mechanism the baseline test relies on to stay green.
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: REPOLENS_NPROC=8 resolves deterministically to --max-parallel 8"
run_dryrun "floor-exact" REPOLENS_NPROC=8 --
assert_eq "floor-exact dry-run exits 0" "0" "$LAST_RC"
assert_eq "REPOLENS_NPROC=8 -> --max-parallel 8 (clamp(8,8,32))" \
          "8" "$(resolved_max_parallel "$(last_output)")"

# ---------------------------------------------------------------------------
# AC3 + clamp MID — a between-floor-and-cap core count passes through unchanged,
# so the default scales with the host. (Today's hardcoded 8 makes this RED.)
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: a mid-range core count scales the default (16 -> --max-parallel 16)"
run_dryrun "mid" REPOLENS_NPROC=16 --
assert_eq "mid dry-run exits 0" "0" "$LAST_RC"
assert_eq "REPOLENS_NPROC=16 -> --max-parallel 16 (scales with cores)" \
          "16" "$(resolved_max_parallel "$(last_output)")"

# ---------------------------------------------------------------------------
# clamp CAP (boundary) — a core count exactly at the cap stays at the cap.
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: a core count at the cap stays at the cap (32 -> --max-parallel 32)"
run_dryrun "cap-edge" REPOLENS_NPROC=32 --
assert_eq "cap-edge dry-run exits 0" "0" "$LAST_RC"
assert_eq "REPOLENS_NPROC=32 -> --max-parallel 32 (cap is inclusive)" \
          "32" "$(resolved_max_parallel "$(last_output)")"

# ---------------------------------------------------------------------------
# clamp CAP — a core count above the cap is bounded down to 32, so a huge host
# does not over-subscribe RAM / trip provider rate limits. (Today RED.)
# ---------------------------------------------------------------------------
echo ""
echo "Test 5: a core count above the cap clamps down (64 -> --max-parallel 32)"
run_dryrun "cap" REPOLENS_NPROC=64 --
assert_eq "cap dry-run exits 0" "0" "$LAST_RC"
assert_eq "REPOLENS_NPROC=64 clamps down to the cap 32" \
          "32" "$(resolved_max_parallel "$(last_output)")"

# ---------------------------------------------------------------------------
# Robustness — a zero-padded value must be read base-10 ("08" is 8, not octal).
# ---------------------------------------------------------------------------
echo ""
echo "Test 6: a zero-padded REPOLENS_NPROC is parsed base-10 (08 -> --max-parallel 8)"
run_dryrun "octal" REPOLENS_NPROC=08 --
assert_eq "zero-padded dry-run exits 0" "0" "$LAST_RC"
assert_eq "REPOLENS_NPROC=08 is read as 8 (base-10), clamps to floor 8" \
          "8" "$(resolved_max_parallel "$(last_output)")"

# ---------------------------------------------------------------------------
# Robustness — a non-numeric REPOLENS_NPROC must NOT crash the run under
# `set -uo pipefail`; the detector falls back to a real core count and the
# clamp still applies, so the resolved value is a positive integer >= floor.
# ---------------------------------------------------------------------------
echo ""
echo "Test 7: a garbage REPOLENS_NPROC falls back safely (no set -u crash)"
run_dryrun "garbage" REPOLENS_NPROC=not-a-number --
assert_eq "garbage REPOLENS_NPROC still exits 0 (graceful fallback)" "0" "$LAST_RC"
garbage_mp="$(resolved_max_parallel "$(last_output)")"
TOTAL=$((TOTAL + 1))
if [[ "$garbage_mp" =~ ^[0-9]+$ ]] && (( garbage_mp >= 8 )); then
  pass_with "garbage REPOLENS_NPROC resolves to a clamped positive int (>=8): $garbage_mp"
else
  fail_with "garbage REPOLENS_NPROC resolves to a clamped positive int (>=8)" \
            "resolved --max-parallel was: '${garbage_mp:-<none>}'"
fi

# ---------------------------------------------------------------------------
# AC2 — an explicit --max-parallel ALWAYS wins over the auto-default, even when
# the host would auto-resolve much higher. The auto-default only fills the
# unset case.
# ---------------------------------------------------------------------------
echo ""
echo "Test 8: explicit --max-parallel 4 wins over a high auto-default (AC2)"
run_dryrun "explicit-wins" REPOLENS_NPROC=64 -- --max-parallel 4
assert_eq "explicit-flag dry-run exits 0" "0" "$LAST_RC"
assert_eq "explicit --max-parallel 4 overrides the nproc auto-default" \
          "4" "$(resolved_max_parallel "$(last_output)")"

# ---------------------------------------------------------------------------
# AC2 — "never override it": an explicit value BELOW the floor is still honored
# verbatim. The clamp applies ONLY to the auto-default path, never to a value
# the user typed.
# ---------------------------------------------------------------------------
echo ""
echo "Test 9: an explicit value below the floor is honored, not re-clamped (AC2)"
run_dryrun "explicit-subfloor" REPOLENS_NPROC=64 -- --max-parallel 2
assert_eq "explicit-subfloor dry-run exits 0" "0" "$LAST_RC"
assert_eq "explicit --max-parallel 2 is respected (auto-clamp does not apply)" \
          "2" "$(resolved_max_parallel "$(last_output)")"

# ---------------------------------------------------------------------------
# Secondary (research §6) — a non-numeric explicit value is rejected with a
# clear error and a non-zero exit, instead of being accepted silently and
# misbehaving deep in the semaphore engine. (Today: accepted in dry-run -> RED.)
# ---------------------------------------------------------------------------
echo ""
echo "Test 10: a non-numeric --max-parallel is rejected with a non-zero exit"
run_dryrun "bad-nonnumeric" -- --max-parallel abc
assert_ne "non-numeric --max-parallel exits non-zero" "0" "$LAST_RC"
assert_contains "the rejection names the offending flag" \
                "--max-parallel" "$(last_output)"

# ---------------------------------------------------------------------------
# Secondary (research §6) — zero is not a valid concurrency and is rejected too
# (a 0 here would otherwise spin the semaphore on an integer comparison).
# ---------------------------------------------------------------------------
echo ""
echo "Test 11: --max-parallel 0 is rejected with a non-zero exit"
run_dryrun "bad-zero" -- --max-parallel 0
assert_ne "--max-parallel 0 exits non-zero" "0" "$LAST_RC"
assert_contains "the zero rejection names the offending flag" \
                "--max-parallel" "$(last_output)"

# ---------------------------------------------------------------------------
# AC3 (regression guard) — the golden-baseline test must pin REPOLENS_NPROC so
# the 8 committed baselines (which hardcode "--max-parallel 8") still diff clean
# on any host once the default becomes nproc-aware. Without this pin a 16/32-core
# CI runner would render a different value and break all 8 baseline diffs.
# ---------------------------------------------------------------------------
echo ""
echo "Test 12: the rounds-default baseline test pins REPOLENS_NPROC for determinism"
assert_file_matches "test_rounds_default_no_regression.sh references REPOLENS_NPROC" \
                    "$ROUNDS_BASELINE_TEST" 'REPOLENS_NPROC'

# ---------------------------------------------------------------------------
# AC4 — the usage / env help in repolens.sh documents the new nproc-aware
# default (the REPOLENS_NPROC override is the determinism knob it must mention).
# The README copy is the documentation stage's job; the in-script help is the
# implementer's. (Today repolens.sh has zero nproc references -> RED.)
# ---------------------------------------------------------------------------
echo ""
echo "Test 13: repolens.sh usage/env help documents the nproc-aware default (AC4)"
assert_file_matches "repolens.sh help/env text references the REPOLENS_NPROC override" \
                    "$REPO" 'REPOLENS_NPROC'

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
