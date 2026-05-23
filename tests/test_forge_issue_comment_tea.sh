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

# Tests for issue #240 — forge_issue_comment tea (Gitea) backend.
#
# Behavioral contract (derived from research.md and the gh arm at
# lib/forge.sh:881-885):
#   - When FORGE_PROVIDER=tea, forge_issue_comment routes the call through
#     `tea issues comment <issue_number> --body-file <bf>
#                  --repo <project-path> --remote <name>`.
#   - Target binding precedence matches forge_issue_create:
#       FORGE_PROJECT_PATH + FORGE_REMOTE_NAME    (default)
#       FORGE_TEA_LOGIN with the owner/repo arg   (fallback)
#       neither set                               => die
#   - On tea success the wrapper returns 0. Callers in
#     lib/filing.sh:_filing_cross_link_enact only check rc; stdout content
#     is not a strict contract (tea may be silent on success).
#   - tea non-zero exit  => wrapper returns 1 with _forge_warn diagnostic
#     that names the repo.
#   - Missing required args / unreadable body_file remain caller-bug dies.
#
# tea is PATH-shadowed with a fake stub; no real Gitea CLI / network is used.

# shellcheck disable=SC2034  # REPOLENS_FAKE_* vars are exported into the runner subshell by run_comment().

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected to contain '$needle'; got '${haystack:0:300}')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (unexpectedly contained '$needle'; got '${haystack:0:300}')"
  fi
}

assert_rc_zero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected rc=0, got rc=$actual)"
  fi
}

assert_rc_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected non-zero rc, got 0)"
  fi
}

assert_log_empty() {
  local desc="$1" log_file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -s "$log_file" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected no tea invocation, got '$(cat "$log_file")')"
  fi
}

echo ""
echo "=== Test Suite: forge_issue_comment tea backend (issue #240) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
FORGE_TEST_PROJECT="$TMPDIR/audited project"
mkdir -p "$FAKE_BIN"
mkdir -p "$FORGE_TEST_PROJECT"

cat > "$FAKE_BIN/tea" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_TEA_LOG:-/dev/null}"
if [[ -n "${REPOLENS_FAKE_TEA_ARGV_DUMP+x}" ]]; then
  {
    printf '%s\n' "$#"
    for arg in "$@"; do
      printf '<%s>\n' "$arg"
    done
  } > "$REPOLENS_FAKE_TEA_ARGV_DUMP"
fi
if [[ -n "${REPOLENS_FAKE_TEA_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_TEA_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_TEA_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_TEA_STDOUT"
fi
exit "${REPOLENS_FAKE_TEA_RC:-0}"
SH
chmod +x "$FAKE_BIN/tea"

run_comment_tea() {
  (
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    export FORGE_PROVIDER=tea
    [[ -n "${FORGE_PROJECT_PATH+x}" ]] && export FORGE_PROJECT_PATH
    [[ -n "${FORGE_REMOTE_NAME+x}" ]] && export FORGE_REMOTE_NAME
    [[ -n "${FORGE_TEA_LOGIN+x}" ]] && export FORGE_TEA_LOGIN
    for v in REPOLENS_FAKE_TEA_RC REPOLENS_FAKE_TEA_LOG \
             REPOLENS_FAKE_TEA_ARGV_DUMP \
             REPOLENS_FAKE_TEA_STDOUT REPOLENS_FAKE_TEA_STDERR; do
      [[ -n "${!v+x}" ]] && export "${v?}"
    done
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    forge_issue_comment "$@"
  )
}

reset_env() {
  unset REPOLENS_FAKE_TEA_RC REPOLENS_FAKE_TEA_LOG REPOLENS_FAKE_TEA_ARGV_DUMP
  unset REPOLENS_FAKE_TEA_STDOUT REPOLENS_FAKE_TEA_STDERR
  unset FORGE_PROJECT_PATH FORGE_REMOTE_NAME FORGE_TEA_LOGIN
}

body_file="$TMPDIR/body.md"
cat > "$body_file" <<'MD'
Cross-link to sibling cluster.

See related findings in #42.
MD

# ---------------------------------------------------------------------------
# Group 1: tea success path
# ---------------------------------------------------------------------------
echo "--- Group 1: tea success path ---"
echo ""

echo "Test 1: tea comment success -> wrapper returns 0"
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
REPOLENS_FAKE_TEA_RC=0
err_file="$TMPDIR/t1.err"
out="$(run_comment_tea owner/repo 42 "$body_file" 2>"$err_file")"
rc=$?
assert_rc_zero "tea comment success returns 0" "$rc"
assert_eq "no warn on stderr" "" "$(cat "$err_file")"

echo ""
echo "Test 2: tea comment argv matches the expected CLI contract"
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
tea_log="$TMPDIR/t2-tea.log"
argv_dump="$TMPDIR/t2-argv.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_ARGV_DUMP="$argv_dump"
REPOLENS_FAKE_TEA_RC=0
out="$(run_comment_tea owner/repo 42 "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
argv_content="$(cat "$argv_dump")"
assert_rc_zero "argv-contract comment succeeds" "$rc"
assert_contains "tea is invoked with 'issues comment'" "issues comment" "$logged"
assert_contains "tea argv carries the issue number positional (42)" \
  "<42>" "$argv_content"
assert_contains "tea argv carries --body-file" "--body-file" "$logged"
assert_contains "tea argv carries the body file path verbatim" \
  "<$body_file>" "$argv_content"
assert_contains "tea argv carries --repo project-path" "--repo" "$logged"
assert_contains "tea argv carries the project path verbatim" \
  "<$FORGE_TEST_PROJECT>" "$argv_content"
assert_contains "tea argv carries --remote origin" "--remote origin" "$logged"

# ---------------------------------------------------------------------------
# Group 2: tea failure semantics
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: tea failure semantics ---"
echo ""

echo "Test 3: tea exits non-zero (404) -> wrapper returns 1 with warn (failure path)"
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
REPOLENS_FAKE_TEA_RC=4
REPOLENS_FAKE_TEA_STDERR='issue not found'
err_file="$TMPDIR/t3.err"
out="$(run_comment_tea owner/repo 999 "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "tea failure returns non-zero" "$rc"
assert_contains "warn mentions tea failed" "tea failed" "$stderr_content"
assert_contains "warn mentions the repo" "owner/repo" "$stderr_content"

# ---------------------------------------------------------------------------
# Group 3: target binding requirement
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: target binding requirement ---"
echo ""

echo "Test 4: missing FORGE_PROJECT_PATH and FORGE_TEA_LOGIN -> die before tea"
reset_env
tea_log="$TMPDIR/t4-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_comment_tea owner/repo 1 "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "missing target binding exits non-zero" "$rc"
assert_contains "die message mentions target binding" "target binding" "$out"
assert_log_empty "missing target binding does not invoke tea" "$tea_log"

echo ""
echo "Test 5: FORGE_TEA_LOGIN fallback when project path is unavailable"
reset_env
FORGE_TEA_LOGIN="work-login"
tea_log="$TMPDIR/t5-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
out="$(run_comment_tea owner/repo 7 "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "FORGE_TEA_LOGIN fallback exits zero" "$rc"
assert_contains "FORGE_TEA_LOGIN fallback uses owner/repo as --repo selector" \
  "--repo owner/repo" "$logged"
assert_contains "FORGE_TEA_LOGIN fallback passes --login <name>" \
  "--login work-login" "$logged"

# ---------------------------------------------------------------------------
# Group 4: stdout + diagnostic edge cases
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 4: stdout + diagnostic edge cases ---"
echo ""

echo "Test 6: tea prints a comment URL -> wrapper echoes first line on stdout"
# The wrapper's contract for callers is: if tea emits anything on stdout
# (older tea versions do print the comment URL), echo the first line through.
# Callers in lib/filing.sh use rc-only, but stdout passthrough is part of the
# implemented behavior and worth pinning.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT="https://gitea.example.com/owner/repo/issues/42#issuecomment-1234"
out="$(run_comment_tea owner/repo 42 "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "tea verbose-success returns 0" "$rc"
assert_eq "wrapper echoes the tea stdout first line" \
  "https://gitea.example.com/owner/repo/issues/42#issuecomment-1234" "$out"

echo ""
echo "Test 7: when tea emits multi-line stdout, only the first line is echoed"
# The wrapper uses '| head -n1' so noisy tea builds (progress + URL) don't
# leak unbounded stdout to callers.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT=$'https://gitea.example.com/owner/repo/issues/42#issuecomment-1\nspurious second line'
out="$(run_comment_tea owner/repo 42 "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "multi-line tea stdout still returns 0" "$rc"
assert_eq "only the first stdout line is forwarded" \
  "https://gitea.example.com/owner/repo/issues/42#issuecomment-1" "$out"

echo ""
echo "Test 8: FORGE_REMOTE_NAME defaults to 'origin' when unset"
# The implementation uses \${FORGE_REMOTE_NAME:-origin}; the comment arm
# must inherit the same safety net as the create arm.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
# Deliberately omit FORGE_REMOTE_NAME
tea_log="$TMPDIR/t8-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
out="$(run_comment_tea owner/repo 5 "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "comment with unset FORGE_REMOTE_NAME succeeds" "$rc"
assert_contains "default remote name is 'origin'" "--remote origin" "$logged"

echo ""
echo "Test 9: tea stderr first line is folded into the warn diagnostic"
# On failure the wrapper must surface what tea was unhappy about plus rc
# plus issue number — operators need this to root-cause cross-link failures.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
REPOLENS_FAKE_TEA_RC=9
REPOLENS_FAKE_TEA_STDERR='permission denied: cannot comment'
err_file="$TMPDIR/t9.err"
out="$(run_comment_tea owner/repo 13 "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "tea permission failure returns non-zero" "$rc"
assert_contains "warn surfaces tea stderr first line" \
  "permission denied: cannot comment" "$stderr_content"
assert_contains "warn includes tea exit code" "rc=9" "$stderr_content"
assert_contains "warn includes the issue number" "issue=13" "$stderr_content"

echo ""
echo "Test 10: custom FORGE_REMOTE_NAME passes through (not hardcoded 'origin')"
# Test 8 covers the unset-defaults-to-origin branch; this pins the
# other side of \${FORGE_REMOTE_NAME:-origin}: when the operator sets
# a non-default remote (e.g. 'upstream'), the wrapper must forward it.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=upstream
tea_log="$TMPDIR/t10-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
out="$(run_comment_tea owner/repo 17 "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "comment with custom FORGE_REMOTE_NAME succeeds" "$rc"
assert_contains "tea argv carries --remote upstream (not origin)" \
  "--remote upstream" "$logged"

echo ""
echo "Test 11: FORGE_PROJECT_PATH takes precedence when FORGE_TEA_LOGIN is also set"
# The target-binding cascade in the implementation checks PROJECT_PATH
# first; the LOGIN branch is the fallback. A user who exports both must
# get the project-path/remote shape (not the login shape).
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
FORGE_TEA_LOGIN="should-be-ignored"
tea_log="$TMPDIR/t11-tea.log"
argv_dump="$TMPDIR/t11-argv.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_ARGV_DUMP="$argv_dump"
REPOLENS_FAKE_TEA_RC=0
out="$(run_comment_tea owner/repo 21 "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
argv_content="$(cat "$argv_dump")"
assert_rc_zero "comment with both env vars succeeds" "$rc"
assert_contains "tea argv uses project-path binding (--repo <project>)" \
  "<$FORGE_TEST_PROJECT>" "$argv_content"
assert_contains "tea argv carries --remote origin (project-path branch)" \
  "--remote origin" "$logged"
assert_not_contains "tea argv must NOT carry --login when project-path wins" \
  "--login" "$logged"
assert_not_contains "tea argv must NOT carry the should-be-ignored login value" \
  "should-be-ignored" "$logged"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
