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

# TDD behavioural contract for issue #382: native support for the official
# Google Gemini CLI as `--agent gemini`.
#
# The chosen design (per the issue research comment) is the PLAIN-TEXT wrapper
# pattern used by codex/opencode — NOT the claude JSON-envelope path:
#
#     gemini --yolo -p "$prompt"
#
#   * `-p` / `--prompt`  -> headless (non-interactive) invocation.
#   * `--yolo`           -> auto-approve all tool/shell calls (unattended lens).
#   * plain text to stdout so the DONE-streak detector reads it unchanged.
#
# Adding gemini touches five choke points in lib/core.sh (validate_agent,
# require_agent_cmd, resolve_agent_timeout, run_agent dispatch) plus a pricing
# entry in config/agent-pricing.json. This file exercises each observable
# contract from the caller's perspective. Every test is RED before the change
# (verified against HEAD) and GREEN after.
#
# NO REAL MODEL IS EVER INVOKED (CLAUDE.md::Tests). `gemini` and `timeout` are
# PATH shims that record their argv and emit canned output; the unit sections
# source lib/core.sh and call its functions directly; the integration section
# drives repolens.sh under --dry-run (no agent executes at all).

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
# Hermetic shims. FAKE_BIN holds recording stand-ins for `gemini` (the new
# agent binary) and `timeout` (so we can observe the wrapper args without a
# real subprocess clock).
# --------------------------------------------------------------------------
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

# gemini shim: records its exact argv into GEMINI_ARGS_MARKER, prints canned
# stdout (default DONE), and exits with a caller-chosen code. This lets a single
# shim serve the dispatch, passthrough, and failure-path scenarios below.
cat > "$FAKE_BIN/gemini" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${GEMINI_ARGS_MARKER:-}" ]]; then
  printf '%s\n' "$*" >> "$GEMINI_ARGS_MARKER"
fi
printf '%s\n' "${GEMINI_STDOUT_TEXT:-DONE}"
exit "${GEMINI_EXIT_CODE:-0}"
SHIM
chmod +x "$FAKE_BIN/gemini"

# timeout shim: records the two leading timeout(1) args plus the wrapped command
# ("$*") so we can prove the gemini arm is wrapped in
# `timeout --kill-after=<grace>s <secs>s`, then shifts those two args and execs
# the real (shimmed) command so exit codes and stdout propagate untouched.
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

GEMINI_ARGS_MARKER="$TMPDIR/gemini-args"
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
echo "=== Section 1: validate_agent accepts gemini ==="

# gemini must join the accept list. Today validate_agent gemini hits the `*)`
# arm and dies; after the change it returns 0.
out="$(validate_agent gemini 2>&1)"; rc=$?
assert_success "validate_agent gemini is accepted" "$rc"

# The reject message for a truly-invalid agent must now advertise gemini as a
# valid option, so operators discover the new value from the error itself.
out="$(validate_agent not-a-real-agent 2>&1)"; rc=$?
assert_failure "a bogus agent is still rejected" "$rc"
assert_contains "reject message advertises gemini as a valid agent" "gemini" "$out"

echo ""
echo "=== Section 2: require_agent_cmd maps gemini -> the gemini binary ==="

# With gemini present on PATH, the preflight passes. Today gemini hits the
# require_agent_cmd `*)` internal-error arm and dies even when the binary exists.
out="$(PATH="$FAKE_BIN:$PATH" require_agent_cmd gemini 2>&1)"; rc=$?
assert_success "require_agent_cmd gemini succeeds when the gemini binary exists" "$rc"

# With gemini absent, it must fail fast through the shared require_cmd path
# (naming the missing binary), not the generic internal-error arm — so a missing
# install is caught at startup, not 200 lenses deep.
NO_GEMINI_BIN="$TMPDIR/nogemini"
mkdir -p "$NO_GEMINI_BIN"
out="$(PATH="$NO_GEMINI_BIN" require_agent_cmd gemini 2>&1)"; rc=$?
assert_failure "require_agent_cmd gemini fails when the binary is missing" "$rc"
assert_contains "missing gemini is reported via require_cmd (names the binary)" \
  "Missing required command: gemini" "$out"

echo ""
echo "=== Section 3: resolve_agent_timeout honours REPOLENS_AGENT_TIMEOUT_GEMINI ==="

# Per-agent override is honoured for gemini (precedence tier 1). Today gemini has
# no agent_vars entry, so this env var is ignored and the default 1800 wins.
out="$(REPOLENS_AGENT_TIMEOUT_GEMINI=17 resolve_agent_timeout audit gemini)"
assert_eq "REPOLENS_AGENT_TIMEOUT_GEMINI is honoured for the gemini agent" "17" "$out"

# Agent-specific override beats the global REPOLENS_AGENT_TIMEOUT — matching the
# documented precedence for every other agent.
out="$(REPOLENS_AGENT_TIMEOUT_GEMINI=17 REPOLENS_AGENT_TIMEOUT=99 resolve_agent_timeout audit gemini)"
assert_eq "gemini-specific timeout wins over the global override" "17" "$out"

# An empty gemini override falls back to the global timeout (edge parity with the
# codex/opencode fallback behaviour already covered elsewhere).
out="$(REPOLENS_AGENT_TIMEOUT_GEMINI='' REPOLENS_AGENT_TIMEOUT=88 resolve_agent_timeout audit gemini)"
assert_eq "empty gemini timeout falls back to the global override" "88" "$out"

# Precedence tier 3: with no agent-specific var and no global REPOLENS_AGENT_TIMEOUT,
# the per-mode var applies. Proves the gemini arm feeds the FULL precedence chain
# (agent > global > mode > default), not just its own tier-1 var. Unset the higher
# tiers inside the subshell so an inherited env can't mask the mode fallback.
out="$(unset REPOLENS_AGENT_TIMEOUT REPOLENS_AGENT_TIMEOUT_GEMINI
       REPOLENS_AGENT_TIMEOUT_AUDIT=44 resolve_agent_timeout audit gemini)"
assert_eq "gemini falls back to the per-mode timeout when no agent/global var is set" "44" "$out"

# Precedence tier 4 (baseline): with NO timeout env at all, gemini resolves to the
# hardcoded 1800 default. Guards against the new gemini arm accidentally
# short-circuiting the fall-through (e.g. returning early with a wrong value).
out="$(unset REPOLENS_AGENT_TIMEOUT REPOLENS_AGENT_TIMEOUT_GEMINI REPOLENS_AGENT_TIMEOUT_AUDIT
       resolve_agent_timeout audit gemini)"
assert_eq "gemini uses the hardcoded 1800 default when no timeout env is set" "1800" "$out"

echo ""
echo "=== Section 4: run_agent gemini dispatches the plain-text wrapper ==="

AGENT_PROJECT="$TMPDIR/agent-proj"
mkdir -p "$AGENT_PROJECT"

# 4a. Dispatch shape: gemini is invoked as `gemini --yolo -p <prompt>`, wrapped
# in `timeout --kill-after=<grace>s <secs>s`. run_agent's 4th/5th positional args
# are timeout_secs=5 and kill_grace_secs=1, so the wrapper must read
# `--kill-after=1s 5s`.
: > "$GEMINI_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       GEMINI_ARGS_MARKER="$GEMINI_ARGS_MARKER" \
       GEMINI_STDOUT_TEXT="hello from gemini" \
       run_agent gemini "GEMINI_PROMPT_MARKER" "$AGENT_PROJECT" 5 1 2>&1)"
rc=$?
timeout_args="$(cat "$TIMEOUT_MARKER")"
gemini_args="$(cat "$GEMINI_ARGS_MARKER")"

assert_success "run_agent gemini exits 0 on a successful run" "$rc"
assert_contains "gemini is wrapped in timeout --kill-after=1s 5s" \
  "--kill-after=1s 5s gemini" "$timeout_args"
assert_contains "gemini gets the --yolo autonomy flag" "--yolo" "$gemini_args"
assert_contains "gemini gets the headless -p prompt flag with the prompt" \
  "-p GEMINI_PROMPT_MARKER" "$gemini_args"

# 4b. Plain-text passthrough: the gemini stdout reaches the caller verbatim so
# the DONE-streak detector reads it. (Confirms the codex/opencode text path, not
# the claude JSON path.)
assert_contains "gemini stdout is passed through to the caller as plain text" \
  "hello from gemini" "$out"

# 4c. NOT the JSON-envelope path: a Gemini answer that happens to look like JSON
# must survive intact — never reduced to a `.result` field the way the claude arm
# extracts. If an implementer wrongly copies the claude JSON path, the `.response`
# key below would be stripped.
: > "$GEMINI_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       GEMINI_ARGS_MARKER="$GEMINI_ARGS_MARKER" \
       GEMINI_STDOUT_TEXT='{"result":"WRONG_EXTRACTED","response":"real answer"}' \
       run_agent gemini "p" "$AGENT_PROJECT" 5 1 2>&1)"
assert_contains "JSON-shaped gemini output is not collapsed to .result" \
  '"response":"real answer"' "$out"

# 4d. Failure-path (MANDATORY): when gemini exits non-zero, run_agent must
# propagate the REAL exit code, not swallow it to 0. 42 is Gemini's documented
# input-error code and is deliberately distinct from die's generic 1, so a rc of
# 42 proves genuine propagation of the child's status through the timeout wrapper.
: > "$GEMINI_ARGS_MARKER"; : > "$TIMEOUT_MARKER"
out="$(PATH="$FAKE_BIN:$PATH" \
       FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
       GEMINI_ARGS_MARKER="$GEMINI_ARGS_MARKER" \
       GEMINI_EXIT_CODE=42 \
       run_agent gemini "p" "$AGENT_PROJECT" 5 1 2>&1)"
rc=$?
assert_eq "run_agent gemini propagates a failing gemini exit code" "42" "$rc"

echo ""
echo "=== Section 5: --dry-run --agent gemini is accepted and priced as gemini ==="

# End-to-end through repolens.sh: parse -> validate_agent -> require_agent_cmd ->
# dry-run cost preview must all accept gemini, and the cost estimate must price
# the run with a Gemini model rather than silently falling back to the
# opencode-default label (config/agent-pricing.json entry, research item #6).
GIT_PROJECT="$TMPDIR/dry-proj"
mkdir -p "$GIT_PROJECT"
git -C "$GIT_PROJECT" init -q
printf '# gemini dry-run test\nprint("x")\n' > "$GIT_PROJECT/a.py"
git -C "$GIT_PROJECT" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 || true
git -C "$GIT_PROJECT" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true

DRY_OUT="$TMPDIR/dry-out.txt"
PATH="$FAKE_BIN:$PATH" \
  bash "$REPOLENS_SH" \
    --project "$GIT_PROJECT" \
    --agent gemini \
    --mode audit \
    --domain security \
    --dry-run \
    --yes \
    --local \
    --output "$TMPDIR/issues-gemini" \
    >"$DRY_OUT" 2>&1
rc=$?
dry_output="$(cat "$DRY_OUT")"
run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$DRY_OUT" 2>/dev/null | head -1 | awk '{print $3}')"
[[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")

# The cost breakdown emits a `  model:      <label>  —  ...` line for the
# resolved agent model; isolate it for the pricing assertions.
model_line="$(grep -iE '^[[:space:]]*model:' "$DRY_OUT" | head -1)"

assert_success "--dry-run --agent gemini exits 0" "$rc"
assert_contains "gemini dry-run reaches completion" "Dry run complete" "$dry_output"
assert_contains "cost estimate resolves a Gemini model" "gemini" "${model_line,,}"
assert_not_contains "gemini is not mispriced as the opencode-default fallback" \
  "opencode" "${model_line,,}"

echo ""
echo "=== Section 6: a real scan actually dispatches a lens to the gemini binary ==="

# Sections 4-5 prove the run_agent unit call and the --dry-run preflight. NEITHER
# exercises a real scan reaching run_agent gemini: --dry-run stops before any
# agent runs. This section drives a full single-lens scan (--depth 1) under
# recording shims and NO fake `timeout` (the real timeout wraps the gemini arm),
# proving the whole parse -> route -> run_agent gemini -> DONE-streak path works
# and that gemini's plain-text DONE actually drives the streak to completion.
E2E_BIN="$TMPDIR/e2e-bin"
mkdir -p "$E2E_BIN"
# Each agent shim records the basename it was invoked as — an exact proxy for
# "which agent ran this lens", since run_agent dispatches a distinct binary per
# agent — and emits DONE so the DONE-x1 streak (--depth 1) completes in one pass.
for _e2e_bin in gemini claude codex opencode; do
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
  printf '# gemini e2e dispatch test\n' > "$project/README.md"
  git -C "$project" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 || true
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true
}
e2e_register_run_id() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  [[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")
}

# 6a. `--agent gemini` end-to-end: the security lens must be run by the gemini
# binary (and nothing else), and the scan must complete cleanly — proving the
# real parse->validate->route->run_agent gemini->streak path, not just the
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
    --agent gemini \
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
assert_success "--agent gemini end-to-end scan exits 0" "$rc"
assert_contains "the lens is actually run by the gemini binary" "gemini" "$e2e_invoked_a"
assert_not_contains "no other agent binary runs the lens under --agent gemini" \
  "codex" "$e2e_invoked_a"

# 6b. `--agent-override <domain>=gemini` routes that domain's lens to gemini even
# though the global agent is codex — the transitive routing the implementation
# claims comes "for free" because override values validate through validate_agent.
# Asserts both the dispatch (gemini binary ran the lens, codex did not) and the
# audit routing note that a completed/resumed run relies on.
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
    --agent-override security=gemini \
    --focus authorization \
    --output "$TMPDIR/e2e-issues-b" \
    >"$E2E_OUT_B" 2>&1
rc=$?
e2e_register_run_id "$E2E_OUT_B"
e2e_invoked_b="$(cat "$E2E_LOG_B")"
e2e_out_b="$(cat "$E2E_OUT_B")"
assert_success "--agent-override security=gemini scan exits 0" "$rc"
assert_contains "the overridden security lens is routed to the gemini binary" \
  "gemini" "$e2e_invoked_b"
assert_not_contains "the global codex does NOT run the overridden security lens" \
  "codex" "$e2e_invoked_b"
assert_contains "the routing note records the gemini override for audit" \
  "Routed to agent 'gemini'" "$e2e_out_b"

echo ""
echo "=== Section 7: --help advertises gemini and its timeout env var (in sync with code) ==="

# This feature's first review was DENIED because `repolens.sh --help` did not list
# `gemini` even though validate_agent accepted it and run_agent dispatched it — the
# in-CLI reference contradicted real behaviour. The fix added `gemini` to the usage
# `--agent` line and a REPOLENS_AGENT_TIMEOUT_GEMINI entry to the Environment: block,
# but NOTHING guarded those additions (test_help_defaults_match_code.sh only checks
# --rounds/--no-verifier). This section locks the fix: if a future edit drops gemini
# from --help while the code still accepts it, these assertions fail.
help_out="$(bash "$REPOLENS_SH" --help 2>&1)"

# Code anchor: validate_agent (sourced above) is the authority on which agents are
# valid. The help text MUST stay in sync with it — so we assert the code fact first,
# then require --help to reflect it, rather than hardcoding an isolated string check.
rc=0; validate_agent gemini >/dev/null 2>&1 || rc=$?
assert_success "validate_agent still accepts gemini (help/code sync anchor)" "$rc"

# The `--agent <agent>` usage line (not the separate --agent-override line) must
# advertise gemini as a valid value, matching validate_agent's accept-list.
agent_usage_line="$(printf '%s\n' "$help_out" | grep -E '^[[:space:]]*--agent ' | head -1)"
assert_contains "--help --agent usage line lists gemini as a valid agent" \
  "gemini" "$agent_usage_line"

# The Environment: block must document the per-agent timeout override so operators
# discover REPOLENS_AGENT_TIMEOUT_GEMINI from --help itself, matching the
# resolve_agent_timeout gemini arm exercised in Section 3.
assert_contains "--help documents the REPOLENS_AGENT_TIMEOUT_GEMINI env var" \
  "REPOLENS_AGENT_TIMEOUT_GEMINI" "$help_out"

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
