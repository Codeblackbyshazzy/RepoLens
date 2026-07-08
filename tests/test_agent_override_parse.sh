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

# Tests for issue #380: Domain-Specific Agent Routing — the `--agent-override`
# CLI flag (v1). Global `--agent` stays the default; `--agent-override` lets an
# operator route specific domains or fully-qualified `domain/lens` keys to a
# different agent (e.g. `--agent opencode --agent-override security=claude`).
#
# This file covers the parse / validate layer, which is fully exercisable with
# `--dry-run` (no model is ever invoked — CLAUDE.md::Tests). The companion file
# tests/test_agent_override_dispatch.sh proves the routing actually switches the
# executed agent per lens using a PATH-shimmed mock binary.
#
# Contract grounded in the current code:
#   - `validate_agent` (lib/core.sh) and the `require_cmd` agent block
#     (repolens.sh) run BEFORE the `--dry-run` preview block, so a malformed
#     override must fail fast even under `--dry-run` — never "200 lenses deep".
#   - An unrecognised flag dies with "Unknown argument: <flag>". Every rejection
#     test below asserts the error does NOT contain "Unknown argument", proving
#     the flag was recognised and the *value* rejected for a real reason (rather
#     than the whole feature being absent) — this is what makes them fail before
#     implementation and pass after.
#   - Lens ids are NOT globally unique (`empty-states` lives in two domains), so
#     a bare lens key is ambiguous; lens-scope overrides must use `domain/lens`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-agent-override-parse"
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
assert_success() {
  local desc="$1" actual="$2"; TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected exit 0, got $actual"; fi
}
assert_failure() {
  local desc="$1" actual="$2"; TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected non-zero exit, got 0"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "Expected to find '$needle'"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then pass_with "$desc"
  else fail_with "$desc" "Did NOT expect to find '$needle'"; fi
}

# Hermetic agent binaries. The parse tests all use --dry-run, so no agent is
# ever executed — but repolens.sh still `require_cmd`s the global agent and every
# override target before the dry-run preview. Shimming claude/codex/opencode onto
# PATH makes require_cmd deterministic regardless of what's installed, and is an
# extra guard that a real model can never be reached. The shim echoes DONE only.
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
for _agent_bin in claude codex opencode; do
  cat > "$FAKE_BIN/$_agent_bin" <<'SHIM'
#!/usr/bin/env bash
echo "DONE"
SHIM
  chmod +x "$FAKE_BIN/$_agent_bin"
done
unset _agent_bin

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# agent-override parse test\n' > "$project/README.md"
  git -C "$project" -c user.email=t@t -c user.name=t add README.md >/dev/null 2>&1 || true
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true
}

register_run_id_from() {
  local out_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  [[ -n "$run_id" ]] && CREATED_RUN_IDS+=("$run_id")
}

# Dry-run wrapper. Global agent is codex; --domain security keeps the lens set
# small and the preview fast. Extra args (the --agent-override under test) append.
run_dry() {
  local out_file="$1" name="$2"
  shift 2
  local project="$TMPDIR/project-$name"
  make_project "$project"
  PATH="$FAKE_BIN:$PATH" \
  bash "$REPOLENS_SH" \
    --project "$project" \
    --agent codex \
    --mode audit \
    --domain security \
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

echo ""
echo "=== Test Suite: --agent-override parse/validate (#380) ==="
echo ""

echo "Test 1: a domain-scoped override is accepted"
out="$TMPDIR/out-domain.txt"
run_dry "$out" "domain" --agent-override security=claude
rc=$?
assert_success "domain override (security=claude) exits 0" "$rc"
assert_contains "dry run reaches completion" "Dry run complete" "$(cat "$out")"

echo ""
echo "Test 2: --help documents --agent-override"
help_out="$(bash "$REPOLENS_SH" --help 2>&1)"
assert_contains "help text mentions --agent-override" "--agent-override" "$help_out"

echo ""
echo "Test 3: a fully-qualified lens key (domain/lens) is accepted"
# Lens-scope overrides MUST use domain/lens because lens ids are not globally
# unique. `security/injection` is a real lens tuple (repolens builds LENS_LIST
# as domain/lens), so this parses and validates cleanly.
out="$TMPDIR/out-lenskey.txt"
run_dry "$out" "lenskey" --agent-override security/injection=claude
rc=$?
assert_success "lens override (security/injection=claude) exits 0" "$rc"

echo ""
echo "Test 4: an opencode/<model> value survives the first-'=' split"
# Override *values* may contain '/'. Pairs must split on the FIRST '=' only, so
# the value 'opencode/gpt-x' is preserved intact and validated as a valid agent
# (validate_agent accepts opencode/<model>). A naive split would corrupt it.
out="$TMPDIR/out-opencodemodel.txt"
run_dry "$out" "opencodemodel" --agent-override security=opencode/gpt-x
rc=$?
assert_success "opencode/<model> override exits 0" "$rc"

echo ""
echo "Test 5: an invalid override agent fails fast and names the bad agent"
# validate_agent runs before the dry-run preview, so a bogus override target
# must abort up front (not mid-scan). The error must name the offending agent
# and must NOT be the generic unknown-flag error (which would mean the flag
# itself is unrecognised, i.e. the feature is absent).
out="$TMPDIR/out-badagent.txt"
run_dry "$out" "badagent" --agent-override security=bogus
rc=$?
badagent_output="$(cat "$out")"
assert_failure "invalid override agent exits non-zero" "$rc"
assert_contains "error names the bad agent 'bogus'" "bogus" "$badagent_output"
assert_not_contains "flag is recognised (not an unknown-argument error)" \
  "Unknown argument" "$badagent_output"

echo ""
echo "Test 6: an empty override value is rejected"
out="$TMPDIR/out-emptyval.txt"
run_dry "$out" "emptyval" --agent-override security=
rc=$?
emptyval_output="$(cat "$out")"
assert_failure "empty override value exits non-zero" "$rc"
assert_not_contains "empty value is a value error, not an unknown-argument error" \
  "Unknown argument" "$emptyval_output"

echo ""
echo "Test 7: an empty opencode model (opencode/) is rejected"
out="$TMPDIR/out-emptymodel.txt"
run_dry "$out" "emptymodel" --agent-override security=opencode/
rc=$?
emptymodel_output="$(cat "$out")"
assert_failure "opencode/ (missing model) exits non-zero" "$rc"
assert_not_contains "empty model is a value error, not an unknown-argument error" \
  "Unknown argument" "$emptymodel_output"

echo ""
echo "Test 8: an unknown/typo'd override key is rejected and named"
# A misspelled domain (matches no domain in domains.json) must fail loudly, else
# the override silently no-ops and the routing the operator asked for never
# happens — the exact footgun this feature exists to prevent.
out="$TMPDIR/out-badkey.txt"
run_dry "$out" "badkey" --agent-override secrutiy=claude
rc=$?
badkey_output="$(cat "$out")"
assert_failure "unknown override key exits non-zero" "$rc"
assert_contains "error names the offending key 'secrutiy'" "secrutiy" "$badkey_output"
assert_not_contains "bad key is a validation error, not an unknown-argument error" \
  "Unknown argument" "$badkey_output"

echo ""
echo "Test 9: a bare, ambiguous lens key is rejected"
# `empty-states` is a lens id that exists in TWO domains, so a bare
# `empty-states=` key is ambiguous (and is not a domain id either). It must be
# rejected in favour of the unambiguous domain/lens form.
dup_count="$(jq -r '.domains[].lenses[]' "$DOMAINS_FILE" | sort | uniq -d | grep -c '^empty-states$')"
assert_contains "fixture precondition: empty-states is a duplicated lens id" "1" "$dup_count"
out="$TMPDIR/out-ambiguous.txt"
run_dry "$out" "ambiguous" --agent-override empty-states=claude
rc=$?
ambiguous_output="$(cat "$out")"
assert_failure "bare ambiguous lens key exits non-zero" "$rc"
assert_contains "error names the ambiguous key 'empty-states'" "empty-states" "$ambiguous_output"
assert_not_contains "ambiguity is a validation error, not an unknown-argument error" \
  "Unknown argument" "$ambiguous_output"

echo ""
echo "Test 10: no --agent-override behaves exactly as before (regression guard)"
# Without the flag, the run must be unchanged: a normal dry-run that completes
# and still reports the single global agent.
out="$TMPDIR/out-noflag.txt"
run_dry "$out" "noflag"
rc=$?
noflag_output="$(cat "$out")"
assert_success "no-override dry-run exits 0" "$rc"
assert_contains "no-override dry-run completes normally" "Dry run complete" "$noflag_output"
assert_contains "no-override run still reports the global agent" "codex" "$noflag_output"

echo ""
echo "Test 11: multiple key=agent pairs in one CSV all populate the routing map"
# A single --agent-override carries a comma-separated LIST; every pair must be
# parsed, not just the first. print_agent_override_map surfaces the active map in
# the preview, so a domain mapping AND a lens mapping given together must both
# appear there.
out="$TMPDIR/out-multi.txt"
run_dry "$out" "multi" --agent-override security=claude,security/injection=opencode
rc=$?
multi_output="$(cat "$out")"
assert_success "multi-pair CSV exits 0" "$rc"
assert_contains "preview prints the override map header" "Agent overrides:" "$multi_output"
assert_contains "domain mapping is shown in the map" "security -> claude" "$multi_output"
assert_contains "lens mapping is shown in the map" "security/injection -> opencode" "$multi_output"

echo ""
echo "Test 12: repeated --agent-override flags accumulate (not last-wins)"
# The flag accumulates across repeated occurrences (AGENT_OVERRIDE_CSV appends
# with a comma). A first-flag mapping and a second-flag mapping must BOTH survive
# into the map — a naive last-wins parse would drop the first.
out="$TMPDIR/out-repeat.txt"
run_dry "$out" "repeat" \
  --agent-override security=claude \
  --agent-override security/injection=opencode
rc=$?
repeat_output="$(cat "$out")"
assert_success "repeated flags exit 0" "$rc"
assert_contains "first flag's mapping survives accumulation" "security -> claude" "$repeat_output"
assert_contains "second flag's mapping survives accumulation" "security/injection -> opencode" "$repeat_output"

echo ""
echo "Test 13: no --agent-override prints no override map section (no-op)"
# print_agent_override_map must be a no-op with no overrides, so the untouched
# preview must NOT sprout an 'Agent overrides:' section.
out="$TMPDIR/out-nomap.txt"
run_dry "$out" "nomap"
rc=$?
nomap_output="$(cat "$out")"
assert_success "no-override dry-run exits 0" "$rc"
assert_not_contains "no override map header when no overrides are set" "Agent overrides:" "$nomap_output"

echo ""
echo "Test 14: a pair with no '=' is rejected as malformed (not key=agent form)"
# 'securityclaude' has no '=' so it cannot be split into key/agent; it must die
# with a form-error, not silently be treated as a key with an empty agent.
out="$TMPDIR/out-noeq.txt"
run_dry "$out" "noeq" --agent-override securityclaude
rc=$?
noeq_output="$(cat "$out")"
assert_failure "pair without '=' exits non-zero" "$rc"
assert_contains "error explains the expected key=agent form" "key=agent form" "$noeq_output"
assert_not_contains "malformed pair is a value error, not an unknown-argument error" \
  "Unknown argument" "$noeq_output"

echo ""
echo "Test 15: an empty override key ('=claude') is rejected"
# The value is present but the key before '=' is empty. That is unroutable and
# must be rejected as an empty-key error (distinct from the empty-value case in
# Test 6).
out="$TMPDIR/out-emptykey.txt"
run_dry "$out" "emptykey" --agent-override =claude
rc=$?
emptykey_output="$(cat "$out")"
assert_failure "empty override key exits non-zero" "$rc"
assert_contains "error names the empty-key problem" "empty override key" "$emptykey_output"
assert_not_contains "empty key is a value error, not an unknown-argument error" \
  "Unknown argument" "$emptykey_output"

echo ""
echo "Test 16: the routed cost estimate is agent-aware and partitioned per agent"
# The feature exists to optimise budget, so with overrides the estimate must
# partition the lens set by EFFECTIVE agent and price each group with its own
# model — not silently reprice the whole run at the global agent. Global agent
# here is codex; routing the security domain to claude while keeping the
# injection lens on codex (via the more-specific lens key) must (a) show a
# per-agent breakdown whose counts partition the lens total, (b) name BOTH
# models, and (c) yield a different total than the single-agent baseline.
sec_count="$(jq -r '.domains[] | select(.id=="security") | .lenses | length' "$DOMAINS_FILE")"
claude_expected=$((sec_count - 1))   # security domain -> claude, minus injection (kept on codex)

base_out="$TMPDIR/out-costbase.txt"
run_dry "$base_out" "costbase"
base_cost="$(grep -oE 'Estimated cost: ~\$[0-9.]+' "$base_out" | head -1)"

routed_out="$TMPDIR/out-costrouted.txt"
run_dry "$routed_out" "costrouted" \
  --agent-override security=claude,security/injection=codex
rc=$?
routed_output="$(cat "$routed_out")"
routed_cost="$(grep -oE 'Estimated cost: ~\$[0-9.]+' "$routed_out" | head -1)"
claude_group_line="$(grep "agent 'claude'" "$routed_out" | head -1)"
codex_group_line="$(grep "agent 'codex'" "$routed_out" | head -1)"

assert_success "routed cost dry-run exits 0" "$rc"
assert_contains "claude group is priced over the domain's remaining lenses" \
  "$claude_expected lens(es)" "$claude_group_line"
assert_contains "codex group is priced over the single lens-key lens" \
  "1 lens(es)" "$codex_group_line"
assert_contains "claude's model label appears in the breakdown" "Claude Sonnet 4.6" "$routed_output"
assert_contains "codex's model label appears in the breakdown" "GPT-5 (Codex)" "$routed_output"
# The mixed-agent total must differ from the all-codex baseline for the same lens
# set — proof the estimate reflects the routing, not the global agent's price.
TOTAL=$((TOTAL + 1))
if [[ -n "$base_cost" && -n "$routed_cost" && "$base_cost" != "$routed_cost" ]]; then
  pass_with "routed total ($routed_cost) differs from single-agent baseline ($base_cost)"
else
  fail_with "routed total differs from single-agent baseline" \
    "baseline='$base_cost' routed='$routed_cost'"
fi

echo ""
echo "Test 17: empty CSV segments (trailing/double comma) are skipped, not rejected"
# A trailing comma or an empty segment between two pairs (common in CSVs stitched
# together by CI scripts) must be silently skipped by the parser's empty-pair
# guard — NOT treated as a malformed 'no =' pair (Test 14) nor an empty-key/value
# error. Both real mappings on either side of the empty segment must still land in
# the map, proving the skip is surgical (drops only the blank segment).
out="$TMPDIR/out-emptyseg.txt"
run_dry "$out" "emptyseg" --agent-override "security=claude,,security/injection=opencode,"
rc=$?
emptyseg_output="$(cat "$out")"
assert_success "CSV with empty segments exits 0" "$rc"
assert_contains "empty-segment CSV still reaches completion" "Dry run complete" "$emptyseg_output"
assert_contains "mapping before the empty segment survives" "security -> claude" "$emptyseg_output"
assert_contains "mapping after the empty segment survives" "security/injection -> opencode" "$emptyseg_output"
assert_not_contains "empty segment is not a malformed key=agent-form error" \
  "key=agent form" "$emptyseg_output"

echo ""
echo "Test 18: whitespace around a key=agent pair is trimmed before validation"
# The parser trims surrounding whitespace on the pair, the key, and the value, so
# a CSV written with spaces after commas (' security = claude ') routes exactly
# like the compact form. Without trimming the key would be ' security' (no domain
# match -> unknown-key die) and the value ' claude' (validate_agent rejects it),
# so a clean exit PLUS the un-padded 'security -> claude' mapping in the map is
# proof the trim happened on both sides of the '='.
out="$TMPDIR/out-ws.txt"
run_dry "$out" "ws" --agent-override " security = claude "
rc=$?
ws_output="$(cat "$out")"
assert_success "whitespace-padded pair exits 0" "$rc"
assert_contains "trimmed pair reaches completion" "Dry run complete" "$ws_output"
assert_contains "trimmed mapping appears un-padded in the map" "security -> claude" "$ws_output"
assert_not_contains "padded key was not taken literally (no unknown-key error)" \
  "unknown override key" "$ws_output"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
