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

# Tests for issue #196 - remote deploy CLI flag parsing.
#
# Behavioural contract:
#   - --remote is accepted only for deploy/server dry-runs.
#   - bare host, user@host, and user@host:port targets surface in dry-run
#     output with the resolved port.
#   - --remote-key must name an existing regular file.
#   - --remote-label is accepted as CLI plumbing for later remote auth work.
#   - --remote conflicts with --hosted and Android deploy targets.
#   - --help documents the remote flags.
#
# The tests drive the public CLI in --dry-run mode with a fake agent binary.
# They do not call internal helper functions directly and never invoke a real
# model or SSH command.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPDIR="$(mktemp -d)"
CREATED_LOG_DIRS=()

# shellcheck disable=SC2329
_cleanup() {
  rm -rf "$TMPDIR"
  local d
  for d in "${CREATED_LOG_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap _cleanup EXIT

record_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_rc_zero() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected rc=0, got rc=$rc)"
  fi
}

assert_rc_nonzero() {
  local desc="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected non-zero rc, got rc=0)"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle' in: ${haystack:0:240})"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (unexpected '$needle' present in: ${haystack:0:240})"
  fi
}

record_run_id() {
  local log_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null | head -1 | awk '{print $3}' || true)"
  if [[ -n "${run_id:-}" ]]; then
    CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi
}

# ---------------------------------------------------------------------------
# Fake agent + fixtures
# ---------------------------------------------------------------------------

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
if [[ -n "${FAKE_CLAUDE_ENV_LOG:-}" ]]; then
  {
    printf 'REMOTE_TARGET=%s\n' "${REMOTE_TARGET:-}"
    printf 'REMOTE_USER=%s\n' "${REMOTE_USER:-}"
    printf 'REMOTE_HOST=%s\n' "${REMOTE_HOST:-}"
    printf 'REMOTE_PORT=%s\n' "${REMOTE_PORT:-}"
    printf 'REMOTE_KEY=%s\n' "${REMOTE_KEY:-}"
    printf 'REMOTE_LABEL=%s\n' "${REMOTE_LABEL:-}"
    printf 'REPOLENS_REMOTE_TARGET=%s\n' "${REPOLENS_REMOTE_TARGET:-}"
    printf 'REPOLENS_REMOTE_LABEL=%s\n' "${REPOLENS_REMOTE_LABEL:-}"
    printf 'REPOLENS_REMOTE_SSH_SOCKET=%s\n' "${REPOLENS_REMOTE_SSH_SOCKET:-}"
  } >> "$FAKE_CLAUDE_ENV_LOG"
fi
printf '%s\n' DONE
exit 0
SH
chmod +x "$FAKE_BIN/claude"
export PATH="$FAKE_BIN:$PATH"

PLAIN_DIR="$TMPDIR/plain-target"
mkdir -p "$PLAIN_DIR"
printf '%s\n' "# plain target" > "$PLAIN_DIR/README.md"

APK_DIR="$TMPDIR/apk-target"
mkdir -p "$APK_DIR/app/build/outputs/apk/debug"
: > "$APK_DIR/app/build/outputs/apk/debug/app-debug.apk"
DIRECT_APK="$APK_DIR/app/build/outputs/apk/debug/app-debug.apk"

REMOTE_KEY="$TMPDIR/id_ed25519"
printf '%s\n' "fake private key for CLI validation only" > "$REMOTE_KEY"

REMOTE_KEY_DIR="$TMPDIR/key-dir"
mkdir -p "$REMOTE_KEY_DIR"

run_repolens() {
  local project="$1" log_file="$2"
  shift 2
  set +e
  bash "$REPOLENS" \
    --project "$project" \
    --agent claude \
    "$@" \
    >"$log_file" 2>&1
  local rc=$?
  set -e
  record_run_id "$log_file"
  return "$rc"
}

run_dry_deploy() {
  local project="$1" log_file="$2"
  shift 2
  run_repolens "$project" "$log_file" \
    --mode deploy \
    --local \
    --dry-run \
    --yes \
    "$@"
}

echo ""
echo "=== Test Suite: remote deploy CLI flag parsing (issue #196) ==="
echo ""

# ===========================================================================
# Test 1: --help documents the remote flags near deploy/hosted options
# ===========================================================================
echo "Test 1: help output lists remote deploy flags"
HELP_LOG="$TMPDIR/help.log"
set +e
bash "$REPOLENS" --help >"$HELP_LOG" 2>&1
help_rc=$?
set -e
help_out="$(cat "$HELP_LOG")"

assert_rc_zero "--help exits zero" "$help_rc"
assert_contains "help lists --remote" "--remote <ssh-target>" "$help_out"
assert_contains "help lists --remote-key" "--remote-key <path>" "$help_out"
assert_contains "help lists --remote-label" "--remote-label <text>" "$help_out"

# ===========================================================================
# Test 2: dry-run without --remote keeps the remote line absent
# ===========================================================================
echo ""
echo "Test 2: deploy dry-run without --remote does not show a remote target"
LOG2="$TMPDIR/run2.log"
run_dry_deploy "$PLAIN_DIR" "$LOG2" || rc2=$?
rc2="${rc2:-0}"
out2="$(cat "$LOG2")"

assert_rc_zero "plain deploy dry-run exits zero" "$rc2"
assert_contains "plain deploy reaches dry-run completion" "Dry run complete" "$out2"
assert_not_contains "plain deploy has no remote target line" "Remote target:" "$out2"

# ===========================================================================
# Test 3: bare host defaults to port 22
# ===========================================================================
echo ""
echo "Test 3: --remote bare host defaults to port 22"
LOG3="$TMPDIR/run3.log"
run_dry_deploy "$PLAIN_DIR" "$LOG3" --remote host.example.com || rc3=$?
rc3="${rc3:-0}"
out3="$(cat "$LOG3")"

assert_rc_zero "bare host remote exits zero" "$rc3"
assert_contains "bare host remote line includes default port" \
  "Remote target: host.example.com:22" "$out3"
assert_contains "bare host reaches dry-run completion" "Dry run complete" "$out3"

# ===========================================================================
# Test 4: user@host defaults to port 22
# ===========================================================================
echo ""
echo "Test 4: --remote user@host defaults to port 22"
LOG4="$TMPDIR/run4.log"
run_dry_deploy "$PLAIN_DIR" "$LOG4" --remote ubuntu@host.example.com || rc4=$?
rc4="${rc4:-0}"
out4="$(cat "$LOG4")"

assert_rc_zero "user host remote exits zero" "$rc4"
assert_contains "user host remote line includes default port" \
  "Remote target: ubuntu@host.example.com:22" "$out4"
assert_contains "user host reaches dry-run completion" "Dry run complete" "$out4"

# ===========================================================================
# Test 5: user@host:port preserves the explicit port without duplication
# ===========================================================================
echo ""
echo "Test 5: --remote user@host:port preserves explicit port"
LOG5="$TMPDIR/run5.log"
run_dry_deploy "$PLAIN_DIR" "$LOG5" --remote ubuntu@host.example.com:2222 || rc5=$?
rc5="${rc5:-0}"
out5="$(cat "$LOG5")"

assert_rc_zero "user host port remote exits zero" "$rc5"
assert_contains "user host port remote line includes explicit port" \
  "Remote target: ubuntu@host.example.com:2222" "$out5"
assert_not_contains "explicit port is not duplicated in dry-run output" \
  "ubuntu@host.example.com:2222:2222" "$out5"

# ===========================================================================
# Test 6: host:port without a user preserves the explicit port
# ===========================================================================
echo ""
echo "Test 6: --remote host:port preserves explicit port"
LOG6="$TMPDIR/run6.log"
run_dry_deploy "$PLAIN_DIR" "$LOG6" --remote host.example.com:2200 || rc6=$?
rc6="${rc6:-0}"
out6="$(cat "$LOG6")"

assert_rc_zero "host port remote exits zero" "$rc6"
assert_contains "host port remote line includes explicit port" \
  "Remote target: host.example.com:2200" "$out6"
assert_not_contains "host port output does not invent a remote user" \
  "@host.example.com:2200" "$out6"

# ===========================================================================
# Test 7: --remote-key accepts an existing regular file and is surfaced
# ===========================================================================
echo ""
echo "Test 7: --remote-key accepts an existing key file"
LOG7="$TMPDIR/run7.log"
run_dry_deploy "$PLAIN_DIR" "$LOG7" \
  --remote ubuntu@host.example.com \
  --remote-key "$REMOTE_KEY" \
  --remote-label "Production host" || rc7=$?
rc7="${rc7:-0}"
out7="$(cat "$LOG7")"

assert_rc_zero "remote key file exits zero" "$rc7"
assert_contains "remote key line includes the exact key path" \
  "Remote target: ubuntu@host.example.com:22 (key: $REMOTE_KEY)" "$out7"
assert_not_contains "remote-label is accepted, not rejected as unknown" \
  "Unknown argument: --remote-label" "$out7"

# ===========================================================================
# Test 8: missing --remote-key path fails
# ===========================================================================
echo ""
echo "Test 8: --remote-key rejects a missing file"
LOG8="$TMPDIR/run8.log"
run_dry_deploy "$PLAIN_DIR" "$LOG8" \
  --remote host.example.com \
  --remote-key "$TMPDIR/missing-key" || rc8=$?
rc8="${rc8:-0}"
out8="$(cat "$LOG8")"

assert_rc_nonzero "missing remote key exits non-zero" "$rc8"
assert_contains "missing remote key reports validation failure" \
  "Remote key file does not exist or is not a regular file" "$out8"

# ===========================================================================
# Test 9: directory --remote-key path fails regular-file validation
# ===========================================================================
echo ""
echo "Test 9: --remote-key rejects directories"
LOG9="$TMPDIR/run9.log"
run_dry_deploy "$PLAIN_DIR" "$LOG9" \
  --remote host.example.com \
  --remote-key "$REMOTE_KEY_DIR" || rc9=$?
rc9="${rc9:-0}"
out9="$(cat "$LOG9")"

assert_rc_nonzero "directory remote key exits non-zero" "$rc9"
assert_contains "directory remote key reports validation failure" \
  "Remote key file does not exist or is not a regular file" "$out9"

# ===========================================================================
# Test 10: --remote is deploy-mode only
# ===========================================================================
echo ""
echo "Test 10: --remote is rejected outside deploy mode"
LOG10="$TMPDIR/run10.log"
run_repolens "$SCRIPT_DIR" "$LOG10" \
  --mode audit \
  --local \
  --dry-run \
  --yes \
  --remote host.example.com || rc10=$?
rc10="${rc10:-0}"
out10="$(cat "$LOG10")"

assert_rc_nonzero "--remote outside deploy exits non-zero" "$rc10"
assert_contains "--remote outside deploy reports deploy-mode requirement" \
  "--remote requires --mode deploy" "$out10"

# ===========================================================================
# Test 11: --remote and --hosted are mutually exclusive before Docker checks
# ===========================================================================
echo ""
echo "Test 11: --remote conflicts with --hosted"
LOG11="$TMPDIR/run11.log"
run_dry_deploy "$PLAIN_DIR" "$LOG11" --remote host.example.com --hosted || rc11=$?
rc11="${rc11:-0}"
out11="$(cat "$LOG11")"

assert_rc_nonzero "--remote with hosted exits non-zero" "$rc11"
assert_contains "--remote with hosted reports mutual exclusion" \
  "--remote and --hosted are mutually exclusive" "$out11"
assert_not_contains "--remote with hosted does not fail on Docker first" \
  "--hosted requires Docker" "$out11"

# ===========================================================================
# Test 12: --remote conflicts with Android deploy target classification
# ===========================================================================
echo ""
echo "Test 12: --remote conflicts with Android deploy targets"
LOG12="$TMPDIR/run12.log"
run_dry_deploy "$DIRECT_APK" "$LOG12" --remote host.example.com || rc12=$?
rc12="${rc12:-0}"
out12="$(cat "$LOG12")"

assert_rc_nonzero "--remote with direct APK exits non-zero" "$rc12"
assert_contains "--remote with direct APK reports android incompatibility" \
  "--remote is incompatible with android deploy targets" "$out12"

# ===========================================================================
# Test 13: malformed SSH target fails validation
# ===========================================================================
echo ""
echo "Test 13: malformed --remote target is rejected"
LOG13="$TMPDIR/run13.log"
run_dry_deploy "$PLAIN_DIR" "$LOG13" --remote ubuntu@bad/host || rc13=$?
rc13="${rc13:-0}"
out13="$(cat "$LOG13")"

assert_rc_nonzero "malformed remote target exits non-zero" "$rc13"
assert_contains "malformed remote target reports invalid target" \
  "Invalid --remote target: ubuntu@bad/host" "$out13"

# ===========================================================================
# Test 14: non-numeric SSH target port fails validation
# ===========================================================================
echo ""
echo "Test 14: non-numeric --remote port is rejected"
LOG14="$TMPDIR/run14.log"
run_dry_deploy "$PLAIN_DIR" "$LOG14" --remote host.example.com:ssh || rc14=$?
rc14="${rc14:-0}"
out14="$(cat "$LOG14")"

assert_rc_nonzero "non-numeric remote port exits non-zero" "$rc14"
assert_contains "non-numeric remote port reports invalid port" \
  "Invalid --remote port: ssh" "$out14"

# ===========================================================================
# Test 15: parsed remote state is exported to a real agent invocation
# ===========================================================================
echo ""
echo "Test 15: parsed remote variables are exported to the agent environment"
LOG15="$TMPDIR/run15.log"
ENV15="$TMPDIR/claude-env15.log"
FAKE_CLAUDE_ENV_LOG="$ENV15" run_repolens "$PLAIN_DIR" "$LOG15" \
  --mode deploy \
  --local \
  --yes \
  --focus service-health \
  --remote ubuntu@host.example.com:2222 \
  --remote-key "$REMOTE_KEY" \
  --remote-label "Production host" || rc15=$?
rc15="${rc15:-0}"
out15="$(cat "$LOG15")"
env15="$(cat "$ENV15" 2>/dev/null || true)"

assert_rc_zero "single-lens remote deploy run exits zero" "$rc15"
assert_contains "remote deploy run completed the selected lens" \
  "DONE x1" "$out15"
assert_contains "agent env includes REMOTE_TARGET" \
  "REMOTE_TARGET=ubuntu@host.example.com:2222" "$env15"
assert_contains "agent env includes REMOTE_USER" \
  "REMOTE_USER=ubuntu" "$env15"
assert_contains "agent env includes REMOTE_HOST" \
  "REMOTE_HOST=host.example.com" "$env15"
assert_contains "agent env includes REMOTE_PORT" \
  "REMOTE_PORT=2222" "$env15"
assert_contains "agent env includes REMOTE_KEY" \
  "REMOTE_KEY=$REMOTE_KEY" "$env15"
assert_contains "agent env includes REMOTE_LABEL" \
  "REMOTE_LABEL=Production host" "$env15"
assert_contains "agent env includes prompt remote target" \
  "REPOLENS_REMOTE_TARGET=ubuntu@host.example.com:2222" "$env15"
assert_contains "agent env includes prompt remote label" \
  "REPOLENS_REMOTE_LABEL=Production host" "$env15"
assert_contains "agent env includes nonempty prompt SSH socket setting" \
  "REPOLENS_REMOTE_SSH_SOCKET=none" "$env15"

# ===========================================================================
# Test 16: --remote-label pipe text cannot inject template variables
# ===========================================================================
echo ""
echo "Test 16: --remote-label with pipe text remains literal"
LOG16="$TMPDIR/run16.log"
ENV16="$TMPDIR/claude-env16.log"
FAKE_CLAUDE_ENV_LOG="$ENV16" run_repolens "$PLAIN_DIR" "$LOG16" \
  --mode deploy \
  --local \
  --yes \
  --focus service-health \
  --remote ubuntu@host.example.com:2222 \
  --remote-label "Prod|REPOLENS_REMOTE_TARGET=" || rc16=$?
rc16="${rc16:-0}"
out16="$(cat "$LOG16")"
env16="$(cat "$ENV16" 2>/dev/null || true)"

assert_rc_zero "pipe label remote deploy run exits zero" "$rc16"
assert_contains "pipe label deploy run completed the selected lens" \
  "DONE x1" "$out16"
assert_contains "pipe label preserves prompt remote target in agent env" \
  "REPOLENS_REMOTE_TARGET=ubuntu@host.example.com:2222" "$env16"
assert_contains "pipe label is literal in prompt remote label env" \
  "REPOLENS_REMOTE_LABEL=Prod|REPOLENS_REMOTE_TARGET=" "$env16"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
