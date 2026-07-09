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

# TDD behavioural contract for issue #383: migrate the native Google agent from
# the now-deprecated Gemini CLI (`--agent gemini`, #382) to the official Google
# Antigravity CLI, exposed as `--agent antigravity`.
#
# TWO CORRECTIONS to the issue's proposed invocation (per research.md), both
# locked below because a verbatim copy of the issue text would hard-fail:
#
#   1. The *binary* is `agy` (Antigravity CLI), NOT `antigravity`. The
#      user-facing flag stays `--agent antigravity`, but require_agent_cmd /
#      run_agent must reference the `agy` executable — the same agent-name !=
#      binary-name decoupling the codebase already uses (spark/sparc -> codex).
#   2. The auto-approve flag is `--dangerously-skip-permissions`, NOT the old
#      `--yolo` (removed in the Gemini -> Antigravity transition).
#
# So the chosen dispatch (PLAIN-TEXT wrapper path, like codex/opencode — NOT the
# claude JSON-envelope path) is:
#
#     agy --dangerously-skip-permissions -p "$prompt"
#
#   * `-p`                            -> headless (non-interactive) invocation.
#   * `--dangerously-skip-permissions -> auto-approve all tool/shell calls so an
#                                        unattended lens never blocks on an
#                                        approval prompt (stdin is closed).
#   * plain text to stdout so the DONE-streak detector reads it unchanged.
#
# This is a CLEAN RENAME: `--agent gemini` is REMOVED (the issue explicitly
# rejected keeping the gemini flag; the free/Pro/Ultra gemini binary is already
# dead). Section 8 locks that breaking change so gemini cannot silently linger.
#
# Migration touches five choke points in lib/core.sh (validate_agent,
# require_agent_cmd, resolve_agent_timeout, run_agent dispatch) plus a pricing
# entry in config/agent-pricing.json and the --help text. This file exercises
# each observable contract from the caller's perspective. Every test is RED
# before the change (verified against HEAD) and GREEN after.
#
# NO REAL MODEL IS EVER INVOKED (CLAUDE.md::Tests). `agy` and `timeout` are PATH
# shims that record their argv and emit canned output; the unit sections source
# lib/core.sh and call its functions directly; the integration section drives
# repolens.sh under --dry-run (no agent executes at all).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$SCRIPT_DIR/lib/core.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPDIR="$(mktemp -d)"
CREATED_RUN_IDS=()
cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
}
trap cleanup EXIT

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then pass_with "$desc"
  else fail_with "$desc" "expected='$expected' actual='$actual'"; fi
}
assert_success() {
  local desc="$1" actual="$2"; TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then pass_with "$desc"
  else fail_with "$desc" "expected exit 0, got $actual"; fi
}
assert_failure() {
  local desc="$1" actual="$2"; TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then pass_with "$desc"
  else fail_with "$desc" "expected non-zero exit, got 0"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "expected to find '$needle' in: '$haystack'"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "did NOT expect '$needle' in: '$haystack'"; fi
}

# --------------------------------------------------------------------------
# Hermetic shims. FAKE_BIN holds recording stand-ins for `agy` (the Antigravity
# binary the new agent maps to) and `timeout` (so we can observe the wrapper
# args without a real subprocess clock).
# --------------------------------------------------------------------------
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

# agy shim: records its exact argv into AGY_ARGS_MARKER, prints canned stdout
# (default DONE), and exits with a caller-chosen code. This lets a single shim
# serve the dispatch, passthrough, and failure-path scenarios below.
cat > "$FAKE_BIN/agy" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${AGY_ARGS_MARKER:-}" ]]; then
  printf '%s\n' "$*" >> "$AGY_ARGS_MARKER"
fi
printf '%s\n' "${AGY_STDOUT_TEXT:-DONE}"
exit "${AGY_EXIT_CODE:-0}"
SHIM
chmod +x "$FAKE_BIN/agy"

# timeout shim: records the two leading timeout(1) args plus the wrapped command
# ("$*") so we can prove the antigravity arm is wrapped in
# `timeout --kill-after=<grace>s <secs>s` AND that the wrapped binary is `agy`,
# then shifts those two args and execs the real (shimmed) command so exit codes
# and stdout propagate untouched.
cat > "$FAKE_BIN/timeout" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${FAKE_TIMEOUT_MARKER:-}" ]]; then
  printf '%s\n' "$*" >> "$FAKE_TIMEOUT_MARKER"
fi
shift 2
exec "$@"
SHIM
chmod +x "$FAKE_BIN/timeout"

# claude/codex/opencode shims: only needed so repolens.sh preflight require_cmd
# stays deterministic in the --dry-run integration section (it never runs them).
for _agent_bin in claude codex opencode; do
  printf '#!/usr/bin/env bash\necho DONE\n' > "$FAKE_BIN/$_agent_bin"
  chmod +x "$FAKE_BIN/$_agent_bin"
done
unset _agent_bin

AGY_ARGS_MARKER="$TMPDIR/agy-args"
TIMEOUT_MARKER="$TMPDIR/timeout-args"

# --------------------------------------------------------------------------
# Source lib/core.sh so the unit sections can call the agent functions directly
# (validate_agent / require_agent_cmd / resolve_agent_timeout / run_agent).
# These functions call `die` (which exits) on the error path, so every failing
# call is captured inside a command substitution — its subshell absorbs the exit.
# --------------------------------------------------------------------------
if [[ -f "$CORE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$CORE"
else
  echo "  FAIL: missing $CORE"; exit 1
fi

echo ""
echo "=== Section 1: validate_agent accepts antigravity ==="

# antigravity must join the accept list. Today validate_agent antigravity hits
# the `*)` arm and dies; after the change it returns 0.
out="$(validate_agent antigravity 2>&1)"; rc=$?
assert_success "validate_agent antigravity is accepted" "$rc"

# The reject message for a truly-invalid agent must now advertise antigravity as
# a valid option, so operators discover the new value from the error itself.
out="$(validate_agent not-a-real-agent 2>&1)"; rc=$?
assert_failure "a bogus agent is still rejected" "$rc"
assert_contains "reject message advertises antigravity as a valid agent" "antigravity" "$out"

echo ""
echo "=== Section 2: require_agent_cmd maps antigravity -> the agy binary ==="

# With agy present on PATH, the preflight passes. Today antigravity hits the
# require_agent_cmd `*)` internal-error arm and dies even when the binary exists.
out="$(PATH="$FAKE_BIN:$PATH" require_agent_cmd antigravity 2>&1)"; rc=$?
assert_success "require_agent_cmd antigravity succeeds when the agy binary exists" "$rc"

# With agy absent, it must fail fast through the shared require_cmd path (naming
# the missing binary), not the generic internal-error arm — so a missing install
# is caught at startup, not 200 lenses deep. The message must name `agy`, the
# real binary, not `antigravity` (the flag), proving the correct decoupling.
NO_AGY_BIN="$TMPDIR/noagy"
mkdir -p "$NO_AGY_BIN"
out="$(PATH="$NO_AGY_BIN" require_agent_cmd antigravity 2>&1)"; rc=$?
assert_failure "require_agent_cmd antigravity fails when the agy binary is missing" "$rc"
assert_contains "missing binary is reported as agy via require_cmd (not 'antigravity')" \
  "Missing required command: agy" "$out"

# Negative regression against the issue's wrong wording: a binary literally named
# `antigravity` on PATH must NOT satisfy the preflight — the code must require
# `agy`. If an implementer copies the issue verbatim (require_cmd antigravity),
# this passes wrongly; requiring `agy` makes it fail as it should.
ONLY_ANTIGRAVITY_BIN="$TMPDIR/only-antigravity"
mkdir -p "$ONLY_ANTIGRAVITY_BIN"
printf '#!/usr/bin/env bash\necho DONE\n' > "$ONLY_ANTIGRAVITY_BIN/antigravity"
chmod +x "$ONLY_ANTIGRAVITY_BIN/antigravity"
out="$(PATH="$ONLY_ANTIGRAVITY_BIN" require_agent_cmd antigravity 2>&1)"; rc=$?
assert_failure "a binary named 'antigravity' does NOT satisfy the preflight (agy is required)" "$rc"

echo ""
echo "=== Section 3: resolve_agent_timeout honours REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY ==="

# Per-agent override is honoured for antigravity (precedence tier 1). Today
# antigravity has no agent_vars entry, so this env var is ignored and 1800 wins.
out="$(REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY=17 resolve_agent_timeout audit antigravity)"
assert_eq "REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY is honoured for the antigravity agent" "17" "$out"

# Agent-specific override beats the global REPOLENS_AGENT_TIMEOUT — matching the
# documented precedence for every other agent.
out="$(REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY=17 REPOLENS_AGENT_TIMEOUT=99 resolve_agent_timeout audit antigravity)"
assert_eq "antigravity-specific timeout wins over the global override" "17" "$out"

# An empty antigravity override falls back to the global timeout (edge parity
# with the codex/opencode fallback behaviour already covered elsewhere).
out="$(REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY='' REPOLENS_AGENT_TIMEOUT=88 resolve_agent_timeout audit antigravity)"
assert_eq "empty antigravity timeout falls back to the global override" "88" "$out"

# Precedence tier 3: with no agent-specific var and no global REPOLENS_AGENT_TIMEOUT,
# the per-mode var applies. Proves the antigravity arm feeds the FULL precedence
# chain (agent > global > mode > default), not just its own tier-1 var. Unset the
# higher tiers inside the subshell so an inherited env can't mask the fallback.
out="$(unset REPOLENS_AGENT_TIMEOUT REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY
       REPOLENS_AGENT_TIMEOUT_AUDIT=44 resolve_agent_timeout audit antigravity)"
assert_eq "antigravity falls back to the per-mode timeout when no agent/global var is set" "44" "$out"

# Precedence tier 4 (baseline): with NO timeout env at all, antigravity resolves
# to the hardcoded 1800 default. Guards against the new arm accidentally
# short-circuiting the fall-through (e.g. returning early with a wrong value).
out="$(unset REPOLENS_AGENT_TIMEOUT REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY REPOLENS_AGENT_TIMEOUT_AUDIT
       resolve_agent_timeout audit antigravity)"
assert_eq "antigravity uses the hardcoded 1800 default when no timeout env is set" "1800" "$out"

echo ""
echo "=== Section 4: run_agent antigravity dispatches the agy plain-text wrapper ==="

AGENT_PROJECT="$TMPDIR/agent-proj"
mkdir -p "$AGENT_PROJECT"

# 4a. Dispatch shape: antigravity is invoked as
# `agy --dangerously-skip-permissions -p <prompt>`, wrapped in
# `timeout --kill-after=<grace>s <secs>s`. run_agent's 4th/5th positional args
# are timeout_secs=5 and kill_grace_secs=1, so the wrapper must read
# `--kill-after=1s 5s agy`.
: > "$AGY_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       AGY_ARGS_MARKER="$AGY_ARGS_MARKER" \
       AGY_STDOUT_TEXT="hello from antigravity" \
       run_agent antigravity "SAFE_PROMPT_MARKER" "$AGENT_PROJECT" 5 1 2>&1)"
rc=$?
timeout_args="$(cat "$TIMEOUT_MARKER")"
agy_args="$(cat "$AGY_ARGS_MARKER")"

assert_success "run_agent antigravity exits 0 on a successful run" "$rc"
assert_contains "the agy binary is wrapped in timeout --kill-after=1s 5s" \
  "--kill-after=1s 5s agy" "$timeout_args"
assert_contains "agy gets the --dangerously-skip-permissions autonomy flag" \
  "--dangerously-skip-permissions" "$agy_args"
assert_contains "agy gets the headless -p prompt flag with the prompt" \
  "-p SAFE_PROMPT_MARKER" "$agy_args"

# 4a-neg. Negative regression: the issue text proposed `antigravity --yolo -p`.
# That is wrong on both counts. Assert the dispatch never emits the removed
# `--yolo` flag and never invokes a binary literally named `antigravity`, so a
# future copy-paste of the issue wording can't silently reintroduce the broken
# invocation.
assert_not_contains "dispatch never emits the removed --yolo flag" "--yolo" "$agy_args"
assert_not_contains "no binary literally named 'antigravity' is invoked (agy is used)" \
  "antigravity" "$timeout_args"

# 4b. Plain-text passthrough: the agy stdout reaches the caller verbatim so the
# DONE-streak detector reads it. (Confirms the codex/opencode text path, not the
# claude JSON path.)
assert_contains "agy stdout is passed through to the caller as plain text" \
  "hello from antigravity" "$out"

# 4c. NOT the JSON-envelope path: an Antigravity answer that happens to look like
# JSON must survive intact — never reduced to a `.result` field the way the
# claude arm extracts. If an implementer wrongly copies the claude JSON path, the
# `.response` key below would be stripped.
: > "$AGY_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       AGY_ARGS_MARKER="$AGY_ARGS_MARKER" \
       AGY_STDOUT_TEXT='{"result":"WRONG_EXTRACTED","response":"real answer"}' \
       run_agent antigravity "p" "$AGENT_PROJECT" 5 1 2>&1)"
assert_contains "JSON-shaped agy output is not collapsed to .result" \
  '"response":"real answer"' "$out"

# 4d. Failure-path (MANDATORY): when agy exits non-zero, run_agent must propagate
# the REAL exit code, not swallow it to 0. 42 is deliberately distinct from die's
# generic 1, so a rc of 42 proves genuine propagation of the child's status
# through the timeout wrapper.
: > "$AGY_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       AGY_ARGS_MARKER="$AGY_ARGS_MARKER" \
       AGY_EXIT_CODE=42 \
       run_agent antigravity "p" "$AGENT_PROJECT" 5 1 2>&1)"
rc=$?
assert_eq "run_agent antigravity propagates a failing agy exit code" "42" "$rc"

echo ""
echo "=== Section 5: --dry-run --agent antigravity is accepted and priced as a Gemini model ==="

# End-to-end through repolens.sh: parse -> validate_agent -> require_agent_cmd ->
# dry-run cost preview must all accept antigravity, and the cost estimate must
# price the run with a Gemini-family model rather than silently falling back to
# the opencode-default label (config/agent-pricing.json agent_default_model
# entry: "antigravity": "gemini-2.5-pro").
GIT_PROJECT="$TMPDIR/dry-proj"
mkdir -p "$GIT_PROJECT"
git -C "$GIT_PROJECT" init -q
printf '# antigravity dry-run test\nprint("x")\n' > "$GIT_PROJECT/a.py"
git -C "$GIT_PROJECT" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 || true
git -C "$GIT_PROJECT" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true

DRY_OUT="$TMPDIR/dry-out.txt"
PATH="$FAKE_BIN:$PATH" \
  bash "$REPOLENS_SH" \
    --project "$GIT_PROJECT" \
    --agent antigravity \
    --mode audit \
    --domain security \
    --dry-run \
    --yes \
    --local \
    --output "$TMPDIR/issues-antigravity" \
    >"$DRY_OUT" 2>&1
rc=$?
dry_output="$(cat "$DRY_OUT")"
run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$DRY_OUT" 2>/dev/null | head -1 | awk '{print $3}')"
[[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")

# The cost breakdown emits a `  model:      <label>  —  ...` line for the
# resolved agent model; isolate it for the pricing assertions.
model_line="$(grep -iE '^[[:space:]]*model:' "$DRY_OUT" | head -1)"

assert_success "--dry-run --agent antigravity exits 0" "$rc"
assert_contains "antigravity dry-run reaches completion" "Dry run complete" "$dry_output"
assert_contains "cost estimate resolves a Gemini-family model" "gemini" "${model_line,,}"
assert_not_contains "antigravity is not mispriced as the opencode-default fallback" \
  "opencode" "${model_line,,}"

echo ""
echo "=== Section 6: a real scan actually dispatches a lens to the agy binary ==="

# Sections 4-5 prove the run_agent unit call and the --dry-run preflight. NEITHER
# exercises a real scan reaching run_agent antigravity: --dry-run stops before
# any agent runs. This section drives a full single-lens scan (--depth 1) under
# recording shims and NO fake `timeout` (the real timeout wraps the agy arm),
# proving the whole parse -> route -> run_agent antigravity -> DONE-streak path
# works and that agy's plain-text DONE actually drives the streak to completion.
E2E_BIN="$TMPDIR/e2e-bin"
mkdir -p "$E2E_BIN"
# Each agent shim records the basename it was invoked as — an exact proxy for
# "which agent ran this lens", since run_agent dispatches a distinct binary per
# agent — and emits DONE so the DONE-x1 streak (--depth 1) completes in one pass.
for _e2e_bin in agy claude codex opencode; do
  cat > "$E2E_BIN/$_e2e_bin" <<'SHIM'
#!/usr/bin/env bash
[[ -n "${REPOLENS_OVERRIDE_INVOKE_LOG:-}" ]] && printf '%s\n' "$(basename "$0")" >> "$REPOLENS_OVERRIDE_INVOKE_LOG"
echo "DONE"
SHIM
  chmod +x "$E2E_BIN/$_e2e_bin"
done
unset _e2e_bin

e2e_make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# antigravity e2e dispatch test\n' > "$project/README.md"
  git -C "$project" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 || true
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true
}
e2e_register_run_id() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  [[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")
}

# 6a. `--agent antigravity` end-to-end: the security lens must be run by the agy
# binary (and nothing else), and the scan must complete cleanly — proving the
# real parse->validate->route->run_agent antigravity->streak path, not just the
# white-box run_agent call from Section 4.
E2E_PROJ_A="$TMPDIR/e2e-proj-a"
e2e_make_project "$E2E_PROJ_A"
E2E_LOG_A="$TMPDIR/e2e-invoke-a.log"; : > "$E2E_LOG_A"
E2E_OUT_A="$TMPDIR/e2e-out-a.txt"
PATH="$E2E_BIN:$PATH" \
  REPOLENS_OVERRIDE_INVOKE_LOG="$E2E_LOG_A" \
  REPOLENS_AGENT_TIMEOUT=5 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$REPOLENS_SH" \
    --project "$E2E_PROJ_A" \
    --agent antigravity \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --focus authorization \
    --output "$TMPDIR/e2e-issues-a" \
    >"$E2E_OUT_A" 2>&1
rc=$?
e2e_register_run_id "$E2E_OUT_A"
e2e_invoked_a="$(cat "$E2E_LOG_A")"
assert_success "--agent antigravity end-to-end scan exits 0" "$rc"
assert_contains "the lens is actually run by the agy binary" "agy" "$e2e_invoked_a"
assert_not_contains "no other agent binary runs the lens under --agent antigravity" \
  "codex" "$e2e_invoked_a"

# 6b. `--agent-override <domain>=antigravity` routes that domain's lens to agy
# even though the global agent is codex — the transitive routing the
# implementation claims comes "for free" because override values validate through
# validate_agent. Asserts both the dispatch (agy ran the lens, codex did not) and
# the audit routing note that a completed/resumed run relies on.
E2E_PROJ_B="$TMPDIR/e2e-proj-b"
e2e_make_project "$E2E_PROJ_B"
E2E_LOG_B="$TMPDIR/e2e-invoke-b.log"; : > "$E2E_LOG_B"
E2E_OUT_B="$TMPDIR/e2e-out-b.txt"
PATH="$E2E_BIN:$PATH" \
  REPOLENS_OVERRIDE_INVOKE_LOG="$E2E_LOG_B" \
  REPOLENS_AGENT_TIMEOUT=5 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$REPOLENS_SH" \
    --project "$E2E_PROJ_B" \
    --agent codex \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --agent-override security=antigravity \
    --focus authorization \
    --output "$TMPDIR/e2e-issues-b" \
    >"$E2E_OUT_B" 2>&1
rc=$?
e2e_register_run_id "$E2E_OUT_B"
e2e_invoked_b="$(cat "$E2E_LOG_B")"
e2e_out_b="$(cat "$E2E_OUT_B")"
assert_success "--agent-override security=antigravity scan exits 0" "$rc"
assert_contains "the overridden security lens is routed to the agy binary" \
  "agy" "$e2e_invoked_b"
assert_not_contains "the global codex does NOT run the overridden security lens" \
  "codex" "$e2e_invoked_b"
assert_contains "the routing note records the antigravity override for audit" \
  "Routed to agent 'antigravity'" "$e2e_out_b"

echo ""
echo "=== Section 7: --help advertises antigravity and its timeout env var (in sync with code) ==="

# The #382 gemini feature's first review was DENIED because `repolens.sh --help`
# did not list the agent even though validate_agent accepted it — the in-CLI
# reference contradicted real behaviour. This section locks the same sync for
# antigravity: if a future edit drops antigravity from --help while the code still
# accepts it, these assertions fail.
help_out="$(bash "$REPOLENS_SH" --help 2>&1)"

# Code anchor: validate_agent (sourced above) is the authority on which agents
# are valid. The help text MUST stay in sync with it — so we assert the code fact
# first, then require --help to reflect it, rather than hardcoding an isolated
# string check. Run inside a subshell so that, before the change lands,
# validate_agent's die/exit is contained and doesn't abort the whole suite.
(validate_agent antigravity) >/dev/null 2>&1; rc=$?
assert_success "validate_agent still accepts antigravity (help/code sync anchor)" "$rc"

# The `--agent <agent>` usage line (not the separate --agent-override line) must
# advertise antigravity as a valid value, matching validate_agent's accept-list.
agent_usage_line="$(printf '%s\n' "$help_out" | grep -E '^[[:space:]]*--agent ' | head -1)"
assert_contains "--help --agent usage line lists antigravity as a valid agent" \
  "antigravity" "$agent_usage_line"

# The Environment: block must document the per-agent timeout override so operators
# discover REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY from --help itself, matching the
# resolve_agent_timeout antigravity arm exercised in Section 3.
assert_contains "--help documents the REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY env var" \
  "REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY" "$help_out"

echo ""
echo "=== Section 8: the deprecated gemini agent is fully removed (clean rename) ==="

# The issue explicitly chose a CLEAN BREAK: "Rename the agent flag: Change
# --agent gemini to --agent antigravity", and rejected keeping the gemini flag
# ("Clean breaking changes align better"). The free/Pro/Ultra gemini binary is
# already dead, so leaving a broken --agent gemini arm would mislead users. Lock
# the removal so gemini cannot silently linger alongside antigravity.
out="$(validate_agent gemini 2>&1)"; rc=$?
assert_failure "validate_agent gemini is now rejected (the flag was renamed away)" "$rc"

# The reject message for a bogus agent must no longer advertise gemini as valid,
# so the deprecated value isn't re-suggested to operators.
out="$(validate_agent not-a-real-agent 2>&1)"; rc=$?
assert_not_contains "the reject message no longer advertises the removed gemini agent" \
  "gemini" "$out"

# The --help usage line must not still list the removed gemini value on the
# --agent line (help/code sync in the removal direction).
help_agent_line="$(printf '%s\n' "$help_out" | grep -E '^[[:space:]]*--agent ' | head -1)"
assert_not_contains "--help --agent usage line no longer lists the removed gemini agent" \
  "gemini" "$help_agent_line"

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
