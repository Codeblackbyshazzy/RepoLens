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

# TDD behavioural contract for issue #384: three loosely-coupled asks.
#
#   1. Generalize the `<agent>/<model>` grammar (currently opencode-only) to the
#      native agents claude, codex and antigravity, so an operator can target a
#      specific model on the CLI and — for free, since --agent-override reuses
#      validate_agent — route a domain to `claude/claude-opus-4-7` etc.
#      spark/sparc stay bare presets (the issue's §1 lists only antigravity,
#      claude, codex, opencode for /model), so `spark/foo` remains invalid.
#   2. `--flat-rate` / `REPOLENS_FLAT_RATE=true`: for subscription / free-tier
#      users the marginal cost is $0.00. Flat-rate mode sets cost to $0.00 and
#      surfaces the expected request/quota consumption instead, suppressing the
#      pay-as-you-go "2-5x higher" disclaimer that makes no sense at $0.
#   3. Keyword pricing heuristics in resolve_agent_model(): an unknown model
#      name buckets by substring — cheap (flash/haiku/mini/8b) < pro (default) <
#      premium (opus/ultra) — instead of the arbitrary opencode-default fallback.
#      Explicit ids in models{} still win over the heuristic; cheap keywords are
#      checked before premium so `*-flash-preview` lands cheap, not premium.
#
# WHAT THIS FILE DELIBERATELY DOES NOT PIN:
#   - The exact CLI flag claude/agy use to select a model. research.md flags
#     `claude --model` / `agy --model` as ASSUMPTIONS (the #383 antigravity
#     migration had to correct the issue's proposed invocation twice). So for
#     claude/agy this file only asserts the model string is ROUTED into the argv
#     (and, for claude, that it precedes -p and the JSON-envelope path survives),
#     never a literal flag token. For codex the `-m` flag is already PROVEN (the
#     spark path uses `codex exec --yolo -m ...`), so codex `-m <model>` IS
#     locked.
#   - Exact generic-class prices / labels. The heuristic's real contract is the
#     ORDERING (cheap < pro < premium), asserted on MIN_COST, not magic numbers.
#   - Live CLI quota auto-detection (research de-scopes it: no confirmed
#     machine-readable quota command for claude/agy). Not tested here.
#
# NO REAL MODEL IS EVER INVOKED (CLAUDE.md::Tests). claude/codex/agy/timeout are
# PATH shims that record argv and emit canned output; unit sections source
# lib/core.sh and call its functions directly; integration sections drive
# repolens.sh under --dry-run (no agent executes at all). Every assertion is RED
# before the change and GREEN after.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$SCRIPT_DIR/lib/core.sh"
REPOLENS_SH="$SCRIPT_DIR/repolens.sh"
PRICING_FILE="$SCRIPT_DIR/config/agent-pricing.json"

PASS=0
FAIL=0
TOTAL=0

TMPDIR="$(mktemp -d)"
# Run-ids are logged to a FILE ledger, not a bash array: dry_run_for_agent is
# called via $(...) command substitution (a subshell), so an array append there
# would be lost and its logs/<run-id> dir would leak. A file append survives the
# subshell. Read the ledger and purge the run dirs BEFORE removing TMPDIR.
RUN_ID_LEDGER="$TMPDIR/run-ids.txt"
: > "$RUN_ID_LEDGER"
record_run_id_from() {
  local out_file="$1" rid
  rid="$(grep -oE 'RepoLens run [^ ]+ starting' "$out_file" 2>/dev/null | head -1 | awk '{print $3}')"
  [[ -n "$rid" ]] && printf '%s\n' "$rid" >> "$RUN_ID_LEDGER"
}
# Snapshot the pre-existing log dirs so cleanup can sweep any run dir this test
# created. A run that dies during preflight (e.g. an invalid --agent/override
# before the feature lands) can mkdir logs/<run-id>/ and its attempt-tracking
# artifacts yet die before the "RepoLens run ... starting" line the ledger keys
# on — so the ledger alone misses it. run-all.sh executes tests sequentially, so
# ANY log dir appearing during this test is unambiguously ours to remove.
LOG_SNAPSHOT="$TMPDIR/log-snapshot.txt"
# shellcheck disable=SC2012  # this ls must pair byte-for-byte with the one in cleanup() so comm -13 matches.
ls -d "$SCRIPT_DIR"/logs/*/ 2>/dev/null | sort > "$LOG_SNAPSHOT"
cleanup() {
  local rid dir
  if [[ -f "$RUN_ID_LEDGER" ]]; then
    while IFS= read -r rid; do
      [[ -n "$rid" ]] && rm -rf "$SCRIPT_DIR/logs/$rid"
    done < "$RUN_ID_LEDGER"
  fi
  # Authoritative sweep: remove every log dir created since the snapshot. The
  # path guard keeps rm -rf strictly under this repo's logs/ (defensive).
  if [[ -f "$LOG_SNAPSHOT" ]]; then
    # shellcheck disable=SC2012  # this ls must pair byte-for-byte with the snapshot ls so comm -13 matches.
    while IFS= read -r dir; do
      [[ -n "$dir" && "$dir" == "$SCRIPT_DIR/logs/"* && -d "$dir" ]] && rm -rf "$dir"
    done < <(comm -13 "$LOG_SNAPSHOT" <(ls -d "$SCRIPT_DIR"/logs/*/ 2>/dev/null | sort))
  fi
  rm -rf "$TMPDIR"
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
# Glob match — used to assert argv ORDER (token X appears before token Y)
# without pinning an exact flag name. `pattern` is intentionally unquoted so
# [[ == ]] treats it as a shell glob.
assert_glob() {
  local desc="$1" pattern="$2" haystack="$3"; TOTAL=$((TOTAL + 1))
  # shellcheck disable=SC2053
  if [[ "$haystack" == $pattern ]]; then pass_with "$desc"
  else fail_with "$desc" "pattern '$pattern' did not match: '$haystack'"; fi
}
# Numeric a < b, tolerant of dollar strings like "0.62"/"4.44".
assert_lt() {
  local desc="$1" a="$2" b="$3"; TOTAL=$((TOTAL + 1))
  local res; res="$(awk -v a="${a:-x}" -v b="${b:-x}" 'BEGIN{print (a+0 < b+0)?1:0}')"
  if [[ "$res" == "1" ]]; then pass_with "$desc"
  else fail_with "$desc" "expected $a < $b"; fi
}
# Guards against vacuous passes: an assertion built on an EMPTY grep result
# (e.g. a run that errored before printing a cost) must go red, not silently
# succeed via "" == "" or `"" !contains X`.
assert_nonempty() {
  local desc="$1" v="$2"; TOTAL=$((TOTAL + 1))
  if [[ -n "$v" ]]; then pass_with "$desc"
  else fail_with "$desc" "value was empty"; fi
}

# --------------------------------------------------------------------------
# Hermetic shims. claude/codex/agy each record their argv into
# $ARGV_DIR/<basename> and emit canned stdout (default DONE) with a caller-chosen
# exit code; `timeout` records its wrapper args then execs the wrapped (shimmed)
# command so exit codes and stdout propagate untouched. opencode exists only so
# the --dry-run require_cmd preflight stays deterministic.
# --------------------------------------------------------------------------
FAKE_BIN="$TMPDIR/bin"
ARGV_DIR="$TMPDIR/argv"
mkdir -p "$FAKE_BIN" "$ARGV_DIR"

for _b in claude codex agy; do
  cat > "$FAKE_BIN/$_b" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${ARGV_DIR:-}" ]]; then
  printf '%s\n' "$*" >> "$ARGV_DIR/$(basename "$0")"
fi
printf '%s\n' "${SHIM_STDOUT:-DONE}"
exit "${SHIM_EXIT:-0}"
SHIM
  chmod +x "$FAKE_BIN/$_b"
done
unset _b
printf '#!/usr/bin/env bash\necho DONE\n' > "$FAKE_BIN/opencode"
chmod +x "$FAKE_BIN/opencode"

TIMEOUT_MARKER="$TMPDIR/timeout-args"
cat > "$FAKE_BIN/timeout" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${FAKE_TIMEOUT_MARKER:-}" ]]; then
  printf '%s\n' "$*" >> "$FAKE_TIMEOUT_MARKER"
fi
shift 2
exec "$@"
SHIM
chmod +x "$FAKE_BIN/timeout"

# --------------------------------------------------------------------------
# Source lib/core.sh so the unit sections can call the agent functions directly.
# These functions call `die` (which exits) on the error path, so every failing
# call is captured inside a command substitution / subshell whose exit is absorbed.
# --------------------------------------------------------------------------
if [[ -f "$CORE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$CORE"
else
  echo "  FAIL: missing $CORE"; exit 1
fi

# ==========================================================================
echo ""
echo "=== Section 1: validate_agent accepts <agent>/<model> for native agents ==="
# ==========================================================================

# claude/codex/antigravity gain a /model suffix (mirroring opencode/*). Today
# `claude/x` hits validate_agent's `*)` arm and dies.
for spec in "claude/claude-haiku-4-5" "codex/gpt-5.1-mini" "antigravity/gemini-3-flash"; do
  (validate_agent "$spec") >/dev/null 2>&1; rc=$?
  assert_success "validate_agent accepts $spec" "$rc"
done

# The empty-model guard must mirror the opencode/* one: a trailing slash with no
# model is rejected, so a typo doesn't silently route to a blank model. The guard
# is generic (`${agent#*/}`), not claude-specific, so it must fire for every
# native agent that gained the /model grammar.
(validate_agent "claude/") >/dev/null 2>&1; rc=$?
assert_failure "validate_agent rejects a slash with no model (claude/)" "$rc"
(validate_agent "codex/") >/dev/null 2>&1; rc=$?
assert_failure "validate_agent rejects a slash with no model (codex/)" "$rc"
(validate_agent "antigravity/") >/dev/null 2>&1; rc=$?
assert_failure "validate_agent rejects a slash with no model (antigravity/)" "$rc"
# opencode/ (empty model) must STILL be rejected after the refactor folded the
# original standalone opencode/* arm into the shared claude/*|codex/*|opencode/*|
# antigravity/* arm with a generic `${agent#*/}` guard. Regression: the merge must
# not have dropped opencode's own trailing-slash guard.
(validate_agent "opencode/") >/dev/null 2>&1; rc=$?
assert_failure "validate_agent rejects a slash with no model (opencode/, merged arm)" "$rc"

# Bare native agents keep working unchanged (regression guard).
for bare in claude codex spark sparc opencode antigravity; do
  (validate_agent "$bare") >/dev/null 2>&1; rc=$?
  assert_success "validate_agent still accepts the bare agent '$bare'" "$rc"
done

# spark/sparc stay bare PRESETS — a /model suffix on them is muddy (it would
# fight the hardcoded -m gpt-5.3-codex-spark preset). The issue's §1 lists only
# antigravity/claude/codex/opencode for /model, so spark/<model> is rejected.
(validate_agent "spark/gpt-5") >/dev/null 2>&1; rc=$?
assert_failure "validate_agent rejects spark/<model> (spark is a bare preset)" "$rc"
(validate_agent "sparc/gpt-5") >/dev/null 2>&1; rc=$?
assert_failure "validate_agent rejects sparc/<model> (sparc is a bare preset)" "$rc"

# The dedicated spark/*|sparc/* reject arm exists ONLY to emit an actionable
# hint (use codex/<model>); without it these fall through to the generic *) die,
# whose message says "<agent>/<model>" but never the literal "codex/<model>".
# Asserting the hint means a refactor that dropped the dedicated arm — leaving a
# spark/<model> user with the generic, unhelpful message — goes red here, not
# just any non-zero exit (die writes to stderr; the subshell absorbs its exit).
spark_err="$( (validate_agent "spark/gpt-5") 2>&1 )"
assert_contains "spark/<model> rejection points the user to codex/<model>" \
  "codex/<model>" "$spark_err"
sparc_err="$( (validate_agent "sparc/gpt-5") 2>&1 )"
assert_contains "sparc/<model> rejection points the user to codex/<model>" \
  "codex/<model>" "$sparc_err"

# ==========================================================================
echo ""
echo "=== Section 2: require_agent_cmd maps <agent>/<model> to the right binary ==="
# ==========================================================================

# The slash form must resolve to the SAME underlying binary as the bare agent,
# so a routed run's preflight catches a missing install at startup. Today
# `claude/x` hits require_agent_cmd's `*)` internal-error arm and dies even when
# the binary is present.
out="$(PATH="$FAKE_BIN:$PATH" require_agent_cmd "claude/claude-haiku-4-5" 2>&1)"; rc=$?
assert_success "require_agent_cmd claude/<model> passes when the claude binary exists" "$rc"

out="$(PATH="$FAKE_BIN:$PATH" require_agent_cmd "codex/gpt-5.1" 2>&1)"; rc=$?
assert_success "require_agent_cmd codex/<model> passes when the codex binary exists" "$rc"

out="$(PATH="$FAKE_BIN:$PATH" require_agent_cmd "antigravity/gemini-x" 2>&1)"; rc=$?
assert_success "require_agent_cmd antigravity/<model> passes when the agy binary exists" "$rc"

# antigravity/<model> must require the `agy` binary (name!=binary decoupling),
# and report `agy` — not `antigravity` — when it is missing.
NO_BINS="$TMPDIR/empty-path"; mkdir -p "$NO_BINS"
out="$(PATH="$NO_BINS" require_agent_cmd "antigravity/gemini-x" 2>&1)"; rc=$?
assert_failure "require_agent_cmd antigravity/<model> fails when agy is missing" "$rc"
assert_contains "missing binary for antigravity/<model> is reported as agy" \
  "Missing required command: agy" "$out"

# ==========================================================================
echo ""
echo "=== Section 3: resolve_agent_timeout honours per-agent env for <agent>/<model> ==="
# ==========================================================================

# A routed agent must feed the SAME per-agent timeout tier as its bare form.
# Today `claude/x` matches no arm, so REPOLENS_AGENT_TIMEOUT_CLAUDE is ignored.
out="$(REPOLENS_AGENT_TIMEOUT_CLAUDE=17 resolve_agent_timeout audit "claude/claude-haiku-4-5")"
assert_eq "REPOLENS_AGENT_TIMEOUT_CLAUDE applies to claude/<model>" "17" "$out"

out="$(REPOLENS_AGENT_TIMEOUT_CODEX=23 resolve_agent_timeout audit "codex/gpt-5.1")"
assert_eq "REPOLENS_AGENT_TIMEOUT_CODEX applies to codex/<model>" "23" "$out"

out="$(REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY=29 resolve_agent_timeout audit "antigravity/gemini-x")"
assert_eq "REPOLENS_AGENT_TIMEOUT_ANTIGRAVITY applies to antigravity/<model>" "29" "$out"

# Fall-through still works: with no per-agent var, a routed agent uses the global
# override (proves the new arm doesn't short-circuit the precedence chain).
out="$(unset REPOLENS_AGENT_TIMEOUT_CLAUDE
       REPOLENS_AGENT_TIMEOUT=88 resolve_agent_timeout audit "claude/claude-haiku-4-5")"
assert_eq "claude/<model> falls back to the global REPOLENS_AGENT_TIMEOUT" "88" "$out"

# ==========================================================================
echo ""
echo "=== Section 4: run_agent <agent>/<model> routes the model into the constructed argv ==="
# ==========================================================================

AGENT_PROJECT="$TMPDIR/agent-proj"; mkdir -p "$AGENT_PROJECT"
PROMPT_MARKER="SAFE_PROMPT_MARKER"
MODEL_MARKER="routed-model-xyz"

run_and_capture() {
  # $1 = agent spec, records argv into $ARGV_DIR/<binary>
  local spec="$1" binary="$2"
  : > "$ARGV_DIR/$binary" 2>/dev/null || true
  : > "$TIMEOUT_MARKER"
  PATH="$FAKE_BIN:$PATH" \
    ARGV_DIR="$ARGV_DIR" \
    FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
    run_agent "$spec" "$PROMPT_MARKER" "$AGENT_PROJECT" 5 1 >/dev/null 2>&1
}

# 4a. codex/<model>: the `-m <model>` flag is PROVEN (the spark path already uses
# `codex exec --yolo -m ...`), so it is locked exactly. The model is passed as a
# distinct `-m` argument, not folded into the prompt.
run_and_capture "codex/gpt-5.1-custom" "codex"
codex_argv="$(cat "$ARGV_DIR/codex" 2>/dev/null || true)"
assert_contains "codex/<model> dispatches codex exec --yolo" "exec --yolo" "$codex_argv"
assert_contains "codex/<model> passes the model via -m <model>" "-m gpt-5.1-custom" "$codex_argv"
assert_contains "codex/<model> still passes the prompt" "$PROMPT_MARKER" "$codex_argv"

# 4b. claude/<model>: the exact flag is UNVERIFIED, so we only require the model
# string to be ROUTED into the argv, to PRECEDE the -p prompt flag, and the
# claude JSON-envelope path (--output-format json) plus autonomy flag to survive.
run_and_capture "claude/$MODEL_MARKER" "claude"
claude_argv="$(cat "$ARGV_DIR/claude" 2>/dev/null || true)"
assert_contains "claude/<model> routes the model string into the argv" "$MODEL_MARKER" "$claude_argv"
assert_glob "claude/<model> places the model before the -p prompt flag" \
  "*$MODEL_MARKER*-p $PROMPT_MARKER*" "$claude_argv"
assert_contains "claude/<model> preserves the JSON-envelope path (--output-format json)" \
  "--output-format json" "$claude_argv"
assert_contains "claude/<model> keeps the --dangerously-skip-permissions autonomy flag" \
  "--dangerously-skip-permissions" "$claude_argv"

# 4c. antigravity/<model>: exact flag unverified — require the model string routed
# into the argv, alongside the agy autonomy + headless flags proven by #383.
run_and_capture "antigravity/$MODEL_MARKER" "agy"
agy_argv="$(cat "$ARGV_DIR/agy" 2>/dev/null || true)"
assert_contains "antigravity/<model> routes the model string into the agy argv" "$MODEL_MARKER" "$agy_argv"
assert_contains "antigravity/<model> keeps --dangerously-skip-permissions" \
  "--dangerously-skip-permissions" "$agy_argv"
assert_contains "antigravity/<model> keeps the headless -p prompt flag" \
  "-p $PROMPT_MARKER" "$agy_argv"

# 4d. Regression: a BARE claude invocation is unchanged — it must NOT suddenly
# gain a model flag. The current path is `--output-format json -p` with no model.
: > "$ARGV_DIR/claude"; : > "$TIMEOUT_MARKER"
PATH="$FAKE_BIN:$PATH" ARGV_DIR="$ARGV_DIR" FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
  run_agent "claude" "$PROMPT_MARKER" "$AGENT_PROJECT" 5 1 >/dev/null 2>&1
bare_claude_argv="$(cat "$ARGV_DIR/claude" 2>/dev/null || true)"
assert_contains "bare claude still uses the JSON-envelope path" "--output-format json" "$bare_claude_argv"
assert_not_contains "bare claude does NOT gain a --model flag" "--model" "$bare_claude_argv"

# 4e. Failure-path (MANDATORY): a routed agent that exits non-zero must propagate
# the REAL exit code, not swallow it. 42 is distinct from die's generic 1.
: > "$ARGV_DIR/codex"
PATH="$FAKE_BIN:$PATH" ARGV_DIR="$ARGV_DIR" FAKE_TIMEOUT_MARKER="$TIMEOUT_MARKER" \
  SHIM_EXIT=42 \
  run_agent "codex/gpt-5.1-custom" "$PROMPT_MARKER" "$AGENT_PROJECT" 5 1 >/dev/null 2>&1
rc=$?
assert_eq "run_agent codex/<model> propagates a failing exit code" "42" "$rc"

# ==========================================================================
echo ""
echo "=== Section 5: resolve_agent_model keyword heuristics (via --dry-run) ==="
# ==========================================================================

# resolve_agent_model lives in repolens.sh (a top-level CLI, not safely
# sourceable), so its behaviour is observed through the --dry-run cost preview:
# the breakdown prints a `model:  <label>  —  $in / $out per MTok` line and an
# `Estimated cost: ~$X` line. Same repo + same lens set across runs, so only the
# model keyword varies → MIN_COST differences isolate the heuristic bucket.
HEUR_PROJECT="$TMPDIR/heur-proj"
mkdir -p "$HEUR_PROJECT"
git -C "$HEUR_PROJECT" init -q
# Seed enough source bytes that even the cheap (flash) bucket rounds above $0.00.
for i in $(seq 1 800); do
  printf 'line %d — seed source to keep the repo well above the token threshold for pricing\n' "$i" \
    >> "$HEUR_PROJECT/src.txt"
done
printf '# heuristic pricing fixture\n' > "$HEUR_PROJECT/README.md"
git -C "$HEUR_PROJECT" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 || true
git -C "$HEUR_PROJECT" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || true

# Run a dry-run for a given --agent value; echo the whole dry-run output.
dry_run_for_agent() {
  local agent="$1" name="$2"
  local out_file="$TMPDIR/dry-$name.txt"
  PATH="$FAKE_BIN:$PATH" \
    bash "$REPOLENS_SH" \
      --project "$HEUR_PROJECT" \
      --agent "$agent" \
      --mode audit \
      --domain security \
      --dry-run \
      --yes \
      --local \
      --output "$TMPDIR/issues-$name" \
      >"$out_file" 2>&1
  record_run_id_from "$out_file"
  cat "$out_file"
}
# Extract the numeric estimated cost from a dry-run output.
extract_cost() {
  printf '%s\n' "$1" \
    | grep -oE 'Estimated cost:[[:space:]]*~?\$[0-9]+\.[0-9]+' \
    | head -1 | grep -oE '[0-9]+\.[0-9]+'
}
model_line_of() { printf '%s\n' "$1" | grep -iE '^[[:space:]]*model:' | head -1; }

# 5a. Bucket ordering: flash (cheap) < neutral name (pro/default) < ultra (premium).
# Same claude/ prefix for all three, so only the model-name keyword differs.
flash_out="$(dry_run_for_agent "claude/claude-flashx-9" "flash")"
mid_out="$(dry_run_for_agent "claude/claude-modelx-9" "mid")"
ultra_out="$(dry_run_for_agent "claude/claude-ultrax-9" "ultra")"
flash_cost="$(extract_cost "$flash_out")"
mid_cost="$(extract_cost "$mid_out")"
ultra_cost="$(extract_cost "$ultra_out")"
# Non-empty guards so a run that errored before printing a cost fails loudly
# instead of feeding "" into the comparisons below (red-before, not vacuous).
assert_nonempty "flash-bucket dry-run produced a cost estimate" "$flash_cost"
assert_nonempty "default-bucket dry-run produced a cost estimate" "$mid_cost"
assert_nonempty "ultra-bucket dry-run produced a cost estimate" "$ultra_cost"
assert_lt "flash keyword buckets cheaper than the default (pro) bucket" "$flash_cost" "$mid_cost"
assert_lt "default (pro) bucket is cheaper than the ultra (premium) bucket" "$mid_cost" "$ultra_cost"

# 5b. Cheap-before-premium ordering: a name with BOTH 'flash' and 'preview' must
# land in the CHEAP flash bucket (identical cost to a plain flash name), not the
# premium bucket that 'preview'/'ultra' would otherwise imply.
flashprev_out="$(dry_run_for_agent "claude/gemini-flash-preview-9" "flashprev")"
flashprev_cost="$(extract_cost "$flashprev_out")"
assert_nonempty "flash-preview dry-run produced a cost estimate" "$flashprev_cost"
assert_eq "a *-flash-preview name buckets cheap (same cost as a plain flash name)" \
  "$flash_cost" "$flashprev_cost"
assert_lt "the flash-preview name is still cheaper than the ultra bucket" "$flashprev_cost" "$ultra_cost"

# 5c. Explicit id wins over the heuristic: claude/claude-haiku-4-5 is an exact
# key in models{}, so it prices as that model's real label — NOT a generic
# bucket — even though its name contains the 'haiku' cheap keyword.
haiku_out="$(dry_run_for_agent "claude/claude-haiku-4-5" "explicit-haiku")"
haiku_model_line="$(model_line_of "$haiku_out")"
assert_contains "explicit id claude/claude-haiku-4-5 prices as its real label" \
  "Haiku 4.5" "$haiku_model_line"

# 5d. No opencode-default fallback for a non-opencode routed agent: an unknown
# claude/<model> must bucket via the generic heuristic, never inherit the
# opencode-default label the issue complains about. Anchor on the real priced
# model line so the negative can't pass vacuously on an empty (errored) run.
mid_model_line="$(model_line_of "$mid_out")"
assert_contains "an unknown claude/<model> resolves to a real priced model line" \
  "per MTok" "$mid_model_line"
assert_not_contains "an unknown claude/<model> is NOT mispriced as opencode-default" \
  "opencode" "$mid_model_line"

# 5e. Gemini-substring regression (issue #384 architecture review): the cheap
# keyword 'mini' must be boundary-anchored so the substring in "geMINI" no longer
# buckets EVERY Gemini model into the cheapest (flash) tier. antigravity IS
# Google's Gemini CLI, so this is the primary model space the estimator must price
# right. Cost depends only on the RESOLVED model (not the agent prefix), so the
# flash/pro/premium reference costs from 5a apply across prefixes.
gempro_out="$(dry_run_for_agent "antigravity/gemini-3-pro" "gempro")"
gemultra_out="$(dry_run_for_agent "antigravity/gemini-3-ultra" "gemultra")"
gempro_cost="$(extract_cost "$gempro_out")"
gemultra_cost="$(extract_cost "$gemultra_out")"
assert_nonempty "gemini-3-pro dry-run produced a cost estimate" "$gempro_cost"
assert_nonempty "gemini-3-ultra dry-run produced a cost estimate" "$gemultra_cost"
# gemini-3-pro must NOT fall into the cheap flash bucket (the reported bug): it is
# strictly pricier than a flash name and prices identically to the pro bucket.
assert_lt "gemini-3-pro does NOT bucket as cheap flash (the 'geMINI' collision)" \
  "$flash_cost" "$gempro_cost"
assert_eq "gemini-3-pro buckets pro (same cost as a neutral pro name)" \
  "$mid_cost" "$gempro_cost"
# gemini-3-ultra must reach the premium bucket — before the fix 'mini' matched
# first and stole it into flash, so 'ultra' never won.
assert_eq "gemini-3-ultra buckets premium (ultra wins, not stolen by 'mini')" \
  "$ultra_cost" "$gemultra_cost"

# 5f. The boundary fix must NOT regress legitimate '-mini' models: o3-mini and
# gpt-4o-mini still match the cheap flash bucket via the delimiter-preceded 'mini'.
o3mini_out="$(dry_run_for_agent "codex/o3-mini" "o3mini")"
gpt4omini_out="$(dry_run_for_agent "codex/gpt-4o-mini" "gpt4omini")"
o3mini_cost="$(extract_cost "$o3mini_out")"
gpt4omini_cost="$(extract_cost "$gpt4omini_out")"
assert_nonempty "o3-mini dry-run produced a cost estimate" "$o3mini_cost"
assert_nonempty "gpt-4o-mini dry-run produced a cost estimate" "$gpt4omini_cost"
assert_eq "o3-mini still buckets cheap flash (delimiter-anchored 'mini' match)" \
  "$flash_cost" "$o3mini_cost"
assert_eq "gpt-4o-mini still buckets cheap flash (delimiter-anchored 'mini' match)" \
  "$flash_cost" "$gpt4omini_cost"

# ==========================================================================
echo ""
echo "=== Section 6: --flat-rate / REPOLENS_FLAT_RATE cost display (via --dry-run) ==="
# ==========================================================================

# Control: a normal (pay-as-you-go) dry-run on the same repo shows a non-zero
# cost AND the "2-5x higher" disclaimer — so the flat-rate assertions below are
# meaningful negatives, not vacuous.
control_out="$(dry_run_for_agent "codex" "flat-control")"
assert_contains "control run prints the pay-as-you-go 2-5x disclaimer" "2-5x" "$control_out"

# Flat-rate via the --flat-rate FLAG.
FLAT_OUT="$TMPDIR/flat-flag.txt"
PATH="$FAKE_BIN:$PATH" \
  bash "$REPOLENS_SH" \
    --project "$HEUR_PROJECT" \
    --agent codex \
    --mode audit \
    --domain security \
    --dry-run \
    --yes \
    --local \
    --flat-rate \
    --output "$TMPDIR/issues-flatflag" \
    >"$FLAT_OUT" 2>&1
rc=$?
record_run_id_from "$FLAT_OUT"
flat_output="$(cat "$FLAT_OUT")"
# Anchor the money assertions to the actual "Estimated cost:" line. Before the
# feature exists --flat-rate is an unknown flag that aborts before any cost line
# is printed, so this is empty and the positive assertions go red — rather than
# matching the word "flat" inside an "unknown option: --flat-rate" error.
flat_cost_line="$(printf '%s\n' "$flat_output" | grep -iE 'Estimated cost:' | head -1)"

assert_success "--flat-rate --dry-run exits 0" "$rc"
assert_contains "--flat-rate reaches dry-run completion" "Dry run complete" "$flat_output"
assert_contains "--flat-rate zeroes the monetary cost to \$0.00" "\$0.00" "$flat_cost_line"
assert_contains "--flat-rate labels the estimate as flat-rate on the cost line" \
  "flat" "${flat_cost_line,,}"
assert_contains "--flat-rate surfaces the expected request/quota consumption" \
  "request" "${flat_output,,}"
assert_not_contains "--flat-rate suppresses the pay-as-you-go 2-5x disclaimer" \
  "2-5x" "$flat_cost_line"

# Flat-rate via the REPOLENS_FLAT_RATE ENV VAR — parity with the flag.
ENV_FLAT_OUT="$TMPDIR/flat-env.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_FLAT_RATE=true \
  bash "$REPOLENS_SH" \
    --project "$HEUR_PROJECT" \
    --agent codex \
    --mode audit \
    --domain security \
    --dry-run \
    --yes \
    --local \
    --output "$TMPDIR/issues-flatenv" \
    >"$ENV_FLAT_OUT" 2>&1
rc=$?
record_run_id_from "$ENV_FLAT_OUT"
env_flat_output="$(cat "$ENV_FLAT_OUT")"
env_flat_cost_line="$(printf '%s\n' "$env_flat_output" | grep -iE 'Estimated cost:' | head -1)"
assert_success "REPOLENS_FLAT_RATE=true --dry-run exits 0" "$rc"
assert_contains "REPOLENS_FLAT_RATE=true zeroes the monetary cost to \$0.00" \
  "\$0.00" "$env_flat_cost_line"
assert_not_contains "REPOLENS_FLAT_RATE=true also suppresses the 2-5x disclaimer" \
  "2-5x" "$env_flat_cost_line"

# ==========================================================================
echo ""
echo "=== Section 7: --agent-override synergy accepts and prices a slashed value ==="
# ==========================================================================

# Generalizing the grammar extends --agent-override for free: routing the
# security domain to claude/claude-opus-4-7 must (a) pass parse/validate and
# (b) price that group with the explicit Opus model in the routed breakdown.
OVR_OUT="$TMPDIR/override.txt"
PATH="$FAKE_BIN:$PATH" \
  bash "$REPOLENS_SH" \
    --project "$HEUR_PROJECT" \
    --agent opencode \
    --mode audit \
    --domain security \
    --dry-run \
    --yes \
    --local \
    --agent-override "security=claude/claude-opus-4-7" \
    --output "$TMPDIR/issues-override" \
    >"$OVR_OUT" 2>&1
rc=$?
record_run_id_from "$OVR_OUT"
ovr_output="$(cat "$OVR_OUT")"
assert_success "--agent-override security=claude/claude-opus-4-7 is accepted (dry-run exits 0)" "$rc"
assert_contains "the routed override prices the security group with the explicit Opus model" \
  "Opus 4.7" "$ovr_output"

# ==========================================================================
echo ""
echo "=== Section 8: agent-pricing.json defines the three generic fallback classes ==="
# ==========================================================================

# The heuristic buckets in Section 5 resolve to these config classes, so they
# must exist with NUMERIC prices and be ordered cheap < pro < premium.
for cls in generic-flash-default generic-pro-default generic-premium-default; do
  in_p="$(jq -r --arg m "$cls" '.models[$m].input_per_mtok // empty' "$PRICING_FILE" 2>/dev/null)"
  out_p="$(jq -r --arg m "$cls" '.models[$m].output_per_mtok // empty' "$PRICING_FILE" 2>/dev/null)"
  ok="$(awk -v i="${in_p:-x}" -v o="${out_p:-x}" \
        'BEGIN{print (i ~ /^[0-9]+(\.[0-9]+)?$/ && o ~ /^[0-9]+(\.[0-9]+)?$/) ? 1 : 0}')"
  assert_eq "$cls has numeric input/output prices" "1" "$ok"
done

flash_in="$(jq -r '.models["generic-flash-default"].input_per_mtok // 0' "$PRICING_FILE" 2>/dev/null)"
pro_in="$(jq -r '.models["generic-pro-default"].input_per_mtok // 0' "$PRICING_FILE" 2>/dev/null)"
prem_in="$(jq -r '.models["generic-premium-default"].input_per_mtok // 0' "$PRICING_FILE" 2>/dev/null)"
assert_lt "generic-flash input price < generic-pro input price" "$flash_in" "$pro_in"
assert_lt "generic-pro input price < generic-premium input price" "$pro_in" "$prem_in"

# ==========================================================================
echo ""
echo "=== Section 9: keyword-bucket breadth, opencode fallback, flat-rate body, env truthiness ==="
# ==========================================================================
# Coverage-stage additions: Section 5 proved the flash<pro<premium ORDERING and
# the cheap-before-premium tie-break, but exercised only 'flash'/'ultra' of the
# implementation's keyword lists. A typo in any other keyword (esp. 'lite'/'nano',
# which the implementation ADDED beyond the issue's spec) would silently misprice
# an unknown model. These assertions pin each remaining keyword to its bucket via
# the class label, so a mis-listed keyword is caught. Reuses the Section 5 helpers
# (dry_run_for_agent / model_line_of) and HEUR_PROJECT.

# 9a. Every cheap keyword (flash/haiku/mini/8b/lite/nano) buckets into the flash
# class. The fixture names carry no premium keyword, so cheap-before-premium is
# not in play — a match here means the keyword is genuinely in the cheap list.
for kw in haiku mini 8b lite nano; do
  kw_out="$(dry_run_for_agent "claude/brandnew-${kw}-xq" "cheap-$kw")"
  kw_line="$(model_line_of "$kw_out")"
  assert_nonempty "cheap-keyword '$kw' dry-run produced a model line" "$kw_line"
  assert_contains "unknown claude/<...${kw}...> buckets into the generic flash class" \
    "generic flash/mini class" "$kw_line"
done

# 9b. Premium keywords (opus/ultra/preview) bucket premium when NOT paired with a
# cheap keyword. 'preview' ALONE is premium; only cheap+preview (Section 5b)
# escapes to the flash bucket, so this is the complement of that tie-break test.
for kw in opus preview; do
  kw_out="$(dry_run_for_agent "claude/brandnew-${kw}-xq" "prem-$kw")"
  kw_line="$(model_line_of "$kw_out")"
  assert_nonempty "premium-keyword '$kw' dry-run produced a model line" "$kw_line"
  assert_contains "unknown claude/<...${kw}...> buckets into the generic premium class" \
    "generic premium class" "$kw_line"
done

# 9c. Regression: opencode/<unknown> KEEPS its historical opencode-default
# fallback and is NOT routed through the new generic-* keyword heuristic. Section
# 5d proved a native claude/<model> is not opencode-default; this proves the
# converse — opencode is deliberately excluded from the generic buckets, so a
# refactor that folded it into the heuristic would be caught here.
opc_out="$(dry_run_for_agent "opencode/brandnew-unknown-model-xq" "opencode-fallback")"
opc_line="$(model_line_of "$opc_out")"
assert_nonempty "opencode/<unknown> dry-run produced a model line" "$opc_line"
assert_contains "opencode/<unknown> still falls back to the opencode-default class" \
  "opencode" "$opc_line"
assert_not_contains "opencode/<unknown> is NOT routed into a generic-* bucket" \
  "generic" "$opc_line"

# 9d. Flat-rate body completeness (issue #384's example output). Section 6 checked
# the $0.00 zeroing, the 'flat' label, the word 'request', and 2-5x suppression;
# the issue ALSO mandates an explicit LLM-call count broken down by
# lenses x iterations x rounds, a per-session token line, and quota guidance
# (subscription message cap + free-tier RPM/RPD). Reuses the --flat-rate output
# captured in Section 6 (flat_output) — no extra dry-run.
flat_req_line="$(printf '%s\n' "$flat_output" | grep -iE 'Total expected requests:' | head -1)"
assert_nonempty "flat-rate emits a 'Total expected requests' line" "$flat_req_line"
assert_contains "flat-rate counts the requests as LLM calls" "LLM calls" "$flat_req_line"
assert_contains "flat-rate breaks the count down by lenses x iterations x rounds" \
  "lenses x" "$flat_req_line"
assert_contains "flat-rate shows the per-session token estimate" \
  "Total expected tokens:" "$flat_output"
assert_contains "flat-rate surfaces a subscription message-cap comparison" \
  "Claude Pro" "$flat_output"
assert_contains "flat-rate surfaces a free-tier rate budget (RPM/RPD)" "RPM" "$flat_output"

# 9d-bis. The headline request count must be a REAL computation, not a
# placeholder or a static example: verify the total on the "Total expected
# requests" line equals its own displayed breakdown (lenses x avg_iters x
# rounds). Section 9d asserted only the presence of the text "lenses x", never
# that the printed total is arithmetically derived from lenses/iterations/rounds.
# This self-consistency check is config-agnostic (it reads the three factors and
# the total off the SAME line, so it holds for any lens count / streak / price)
# and catches a total computed with a dropped or different factor — e.g. omitting
# the DONE-streak multiplier, which would silently understate the quota impact the
# whole flat-rate feature exists to surface. Reuses flat_req_line from Section 9d.
frl_total="$(printf '%s\n' "$flat_req_line" | grep -oE '~[0-9]+([.][0-9]+)? LLM calls' | grep -oE '[0-9]+([.][0-9]+)?' | head -1)"
frl_lenses="$(printf '%s\n' "$flat_req_line" | grep -oE '\([0-9]+ lenses' | grep -oE '[0-9]+' | head -1)"
frl_iters="$(printf '%s\n' "$flat_req_line" | grep -oE 'x ~[0-9]+([.][0-9]+)? iterations' | grep -oE '[0-9]+([.][0-9]+)?' | head -1)"
frl_rounds="$(printf '%s\n' "$flat_req_line" | grep -oE 'x [0-9]+ round' | grep -oE '[0-9]+' | head -1)"
assert_nonempty "flat-rate request line exposes a total LLM-call count" "$frl_total"
assert_nonempty "flat-rate request line exposes the lens count" "$frl_lenses"
assert_nonempty "flat-rate request line exposes the avg iterations" "$frl_iters"
assert_nonempty "flat-rate request line exposes the round count" "$frl_rounds"
# want = lenses x avg_iters x rounds; allow max(1, 5%) tolerance so the %.0f/%.1f
# display rounding of the total/iterations never trips a false failure, while a
# gross factor error (wrong or missing multiplier) still exceeds the band.
frl_consistent="$(awk -v t="${frl_total:-x}" -v l="${frl_lenses:-x}" -v i="${frl_iters:-x}" -v r="${frl_rounds:-x}" \
  'BEGIN { want = l * i * r; d = t - want; if (d < 0) d = -d; tol = want * 0.05; if (tol < 1) tol = 1; print (d <= tol) ? 1 : 0 }')"
assert_eq "flat-rate total requests equals lenses x avg_iters x rounds (self-consistent)" \
  "1" "$frl_consistent"

# 9e. REPOLENS_FLAT_RATE truthiness: only true/1/yes (any case) enable flat-rate.
# A falsy value (false / 0 / empty) must leave the pay-as-you-go estimator ON —
# otherwise a stray `REPOLENS_FLAT_RATE=false` in the environment would silently
# hide the real cost. Guards the env-seed case-statement against an "any non-empty
# value is true" regression (which the true-only Section 6 parity test can't see).
FALSY_OUT="$TMPDIR/flat-falsy.txt"
PATH="$FAKE_BIN:$PATH" \
  REPOLENS_FLAT_RATE=false \
  bash "$REPOLENS_SH" \
    --project "$HEUR_PROJECT" \
    --agent codex \
    --mode audit \
    --domain security \
    --dry-run \
    --yes \
    --local \
    --output "$TMPDIR/issues-falsy" \
    >"$FALSY_OUT" 2>&1
rc=$?
record_run_id_from "$FALSY_OUT"
falsy_output="$(cat "$FALSY_OUT")"
falsy_cost_line="$(printf '%s\n' "$falsy_output" | grep -iE 'Estimated cost:' | head -1)"
assert_success "REPOLENS_FLAT_RATE=false --dry-run exits 0" "$rc"
assert_nonempty "REPOLENS_FLAT_RATE=false still prints a cost line" "$falsy_cost_line"
assert_not_contains "REPOLENS_FLAT_RATE=false does NOT enable flat-rate (no \$0.00 flat label)" \
  "0.00 (Flat-Rate" "$falsy_cost_line"
assert_contains "REPOLENS_FLAT_RATE=false keeps the pay-as-you-go 2-5x disclaimer" \
  "2-5x" "$falsy_cost_line"

# ==========================================================================
echo ""
echo "=== Section 10: confirm_autonomous_mode gates claude/<model> like bare claude ==="
# ==========================================================================
# The consent screen that explains --dangerously-skip-permissions is gated on the
# AGENT being claude. run_agent now builds the SAME `claude --dangerously-skip-permissions
# --model <model> ... -p` argv for the claude/<model> path (asserted in Section 4b),
# so the gate MUST also fire for claude/<model> — otherwise an interactive
# `--agent claude/<model>` run silently skips the informed-consent screen that bare
# `--agent claude` shows for the identical CLI + identical flag.
#
# confirm_autonomous_mode lives in repolens.sh (not safely sourceable whole), so we
# extract just that function and eval it in a hermetic subshell. Discriminator: with
# AUTO_YES=false and stdin redirected from /dev/null (never a tty), an agent that
# EARLY-RETURNS exits 0, while an agent that ENTERS the gate hits the
# non-interactive `die` (rc 1, message "...without --yes flag..."). die is already
# sourced from lib/core.sh. No real model is invoked.
CONFIRM_FN_SRC="$(awk '/^confirm_autonomous_mode\(\)/{f=1} f{print} f&&/^\}/{exit}' "$REPOLENS_SH")"
assert_contains "extracted confirm_autonomous_mode source contains the guard" \
  "confirm_autonomous_mode()" "$CONFIRM_FN_SRC"

run_confirm() {
  # $1 = AGENT value, $2 = AUTO_YES value (true|false). Sets CONFIRM_OUT / CONFIRM_RC.
  local agent="$1" auto="$2"
  CONFIRM_OUT="$(
    eval "$CONFIRM_FN_SRC"
    # AGENT/AUTO_YES are consumed by the eval'd confirm_autonomous_mode in this subshell
    # shellcheck disable=SC2034
    AGENT="$agent"
    # shellcheck disable=SC2034
    AUTO_YES="$auto"
    confirm_autonomous_mode </dev/null 2>&1
  )"
  CONFIRM_RC=$?
}

# Non-claude agent: early-returns 0 BEFORE the AUTO_YES/tty checks, so even with
# AUTO_YES=false it exits 0 and never prints the gate.
run_confirm "codex" "false"
assert_success "confirm_autonomous_mode returns 0 immediately for a non-claude agent (codex)" "$CONFIRM_RC"
assert_not_contains "codex never reaches the consent gate" "without --yes" "$CONFIRM_OUT"

# Bare claude: does NOT early-return — it enters the gate and, non-interactively
# without --yes, dies. This is the baseline the claude/<model> path must match.
run_confirm "claude" "false"
assert_failure "confirm_autonomous_mode does NOT early-return for bare claude (enters the gate)" "$CONFIRM_RC"
assert_contains "bare claude reaches the non-interactive --yes guard inside the gate" \
  "without --yes" "$CONFIRM_OUT"

# claude/<model> (the diff's new claude-CLI path): must enter the SAME gate as bare
# claude, not slip past it. Before the fix the exact `== "claude"` test was false
# for claude/<model> so it early-returned 0 here — the regression this pins.
run_confirm "claude/claude-haiku-4-5" "false"
assert_failure "confirm_autonomous_mode does NOT early-return for claude/<model> (same gate as bare claude)" "$CONFIRM_RC"
assert_contains "claude/<model> reaches the same consent gate as bare claude" \
  "without --yes" "$CONFIRM_OUT"

# --yes still short-circuits the gate cleanly for the slash form (return 0, no die):
# the gate is ENTERED but AUTO_YES releases it, proving the fix widened the guard
# without breaking the --yes escape hatch AutoDev/CI rely on.
run_confirm "claude/claude-haiku-4-5" "true"
assert_success "confirm_autonomous_mode with --yes returns 0 for claude/<model>" "$CONFIRM_RC"
assert_not_contains "claude/<model> with --yes does not die on the non-interactive guard" \
  "without --yes" "$CONFIRM_OUT"

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
