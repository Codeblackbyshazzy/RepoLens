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

# Tests for issue #380: Domain-Specific Agent Routing — dispatch behaviour.
#
# The parse suite (tests/test_agent_override_parse.sh) proves the flag is parsed
# and validated. This suite proves the payoff: at scan time the *effective* agent
# for a lens follows the override, with precedence
#     lens key (domain/lens)  >  domain key (domain)  >  global --agent.
#
# No real model is ever invoked (CLAUDE.md::Tests). Each agent binary
# (claude/codex/opencode) is a PATH shim that records which binary name it was
# invoked as and emits DONE so the lens completes in a single iteration. Because
# run_agent dispatches a distinct binary per agent (claude->claude,
# codex->codex, opencode->opencode), the recorded binary name is an exact,
# observable proxy for "which agent ran this lens" — no need to spy on internals.
#
# Each scenario runs a single lens via --focus (fast, one agent call) and
# inspects a fresh invocation log.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-agent-override-dispatch"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected to find '$needle' in: '$haystack'"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "Did NOT expect '$needle' in: '$haystack'"; fi
}

# Recording shims. An absolute FAKE_BIN keeps the shim resolvable after
# run_agent cd's into the project dir; the invocation log is absolute for the
# same reason. Each shim appends its own basename (== the agent's binary) and
# emits DONE so the DONE-x1 streak (--depth 1) completes immediately.
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
for _agent_bin in claude codex opencode; do
  cat > "$FAKE_BIN/$_agent_bin" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${REPOLENS_OVERRIDE_INVOKE_LOG:-}" ]]; then
  printf '%s\n' "$(basename "$0")" >> "$REPOLENS_OVERRIDE_INVOKE_LOG"
fi
echo "DONE"
SHIM
  chmod +x "$FAKE_BIN/$_agent_bin"
done
unset _agent_bin

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# agent-override dispatch test\n' > "$project/README.md"
  git -C "$project" -c user.email=t@t -c user.name=t add README.md >/dev/null 2>&1 || true
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true
}

register_run_id_from() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  [[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")
}

# Run a single-lens scan under the shims. Global agent is codex. Extra args (the
# --focus / --agent-override under test) append. Records the invoked binary
# name(s) into $invoke_log. A tight timeout bounds the (shimmed) run.
INVOKE_LOG=""
run_scan() {
  local out_file="$1" name="$2"
  shift 2
  local project="$TMPDIR/project-$name"
  make_project "$project"
  INVOKE_LOG="$TMPDIR/invoke-$name.log"
  : > "$INVOKE_LOG"
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_OVERRIDE_INVOKE_LOG="$INVOKE_LOG" \
  REPOLENS_AGENT_TIMEOUT=5 \
  REPOLENS_AGENT_KILL_GRACE=1 \
  bash "$REPOLENS_SH" \
    --project "$project" \
    --agent codex \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --output "$TMPDIR/issues-$name" \
    "$@" \
    >"$out_file" 2>&1
  local rc=$?
  register_run_id_from "$out_file"
  return "$rc"
}

echo ""
echo "=== Test Suite: --agent-override dispatch/precedence (#380) ==="
echo ""

echo "Scenario A: no override -> the single global agent runs the lens (control)"
# Establishes the baseline the overrides must change: with no --agent-override,
# the security lens runs under the global --agent codex.
run_scan "$TMPDIR/out-a.txt" "control" --focus authorization
invoked="$(cat "$INVOKE_LOG")"
assert_contains "control: security lens runs under global codex" "codex" "$invoked"
assert_not_contains "control: opencode not invoked" "opencode" "$invoked"
assert_not_contains "control: claude not invoked" "claude" "$invoked"

echo ""
echo "Scenario B: a domain override routes the whole domain to the override agent"
# security=opencode must make the security lens run under opencode instead of the
# global codex.
run_scan "$TMPDIR/out-b.txt" "domain" \
  --focus authorization --agent-override security=opencode
invoked="$(cat "$INVOKE_LOG")"
assert_contains "domain override: security lens runs under opencode" "opencode" "$invoked"
assert_not_contains "domain override: global codex NOT used for security" "codex" "$invoked"
# The run must also LOG the routing decision so a completed run / resume log shows
# which model actually ran each lens (auditability), naming both the effective
# agent and the global default it overrode.
b_output="$(cat "$TMPDIR/out-b.txt")"
assert_contains "domain override: routing note names the effective agent" \
  "Routed to agent 'opencode'" "$b_output"
assert_contains "domain override: routing note records the global agent for audit" \
  "global: codex" "$b_output"

echo ""
echo "Scenario C: a lens key beats a domain key for the same lens"
# Both security=opencode (domain) and security/injection=claude (lens) are set.
# For the injection lens, the more specific lens key must win -> claude, not the
# domain's opencode and not the global codex.
run_scan "$TMPDIR/out-c.txt" "lens-wins" \
  --focus injection \
  --agent-override security=opencode,security/injection=claude
invoked="$(cat "$INVOKE_LOG")"
assert_contains "precedence: injection lens runs under the lens-key agent claude" "claude" "$invoked"
assert_not_contains "precedence: domain-key opencode NOT used for injection" "opencode" "$invoked"
assert_not_contains "precedence: global codex NOT used for injection" "codex" "$invoked"

echo ""
echo "Scenario D: a domain override does NOT leak to lenses in other domains"
# security=opencode routes the security domain, but a lens in a DIFFERENT domain
# (code-quality/naming) matches neither a lens key nor the domain key, so
# resolve_effective_agent falls through to the global agent. This proves routing
# is SELECTIVE — the whole point of the feature — rather than all-or-nothing:
# with an override active, an unrelated lens still runs the global codex and
# emits no routing note. Distinct from Scenario A, where NO override exists at
# all; here the override is present but correctly scoped past this lens.
run_scan "$TMPDIR/out-d.txt" "scoped" \
  --focus naming --agent-override security=opencode
invoked="$(cat "$INVOKE_LOG")"
assert_contains "scoping: out-of-domain lens still runs the global codex" "codex" "$invoked"
assert_not_contains "scoping: security's opencode override does NOT reach naming" "opencode" "$invoked"
d_output="$(cat "$TMPDIR/out-d.txt")"
assert_not_contains "scoping: no routing note is logged for an unrouted lens" \
  "Routed to agent" "$d_output"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
