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

# Tests for issue #240 — forge_issue_create tea (Gitea) backend.
#
# Behavioral contract (derived from research.md and the gh arm at
# lib/forge.sh:830-848):
#   - When FORGE_PROVIDER=tea, forge_issue_create routes the call through
#     the tea CLI: `tea issues create --repo <project-path> --remote <name>
#                  --title <t> --body-file <bf> --labels <csv> --output json`.
#   - Target binding precedence matches forge_label_create / forge_issue_list_count:
#       FORGE_PROJECT_PATH + FORGE_REMOTE_NAME    (default)
#       FORGE_TEA_LOGIN with the owner/repo arg   (fallback)
#       neither set                               => die
#   - Multiple labels are joined as a single CSV (tea idiom), not
#     repeated --label flags (gh idiom).
#   - tea is invoked with --output json and the wrapper parses .html_url
#     from the response and prints it on stdout.
#   - tea exits non-zero  => wrapper returns 1 with _forge_warn diagnostic
#     that mentions the repo and the tea exit code.
#   - tea returns JSON without an html_url  => wrapper returns 1
#     (parse failure observable to callers).
#   - Missing required args / unreadable body_file remain caller-bug dies
#     (already enforced by the function-entry guards).
#
# tea is PATH-shadowed with a fake stub; no real Gitea CLI / network is used.

# shellcheck disable=SC2034  # REPOLENS_FAKE_* vars are exported into the runner subshell by run_create().

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
echo "=== Test Suite: forge_issue_create tea backend (issue #240) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
FORGE_TEST_PROJECT="$TMPDIR/audited project"
mkdir -p "$FAKE_BIN"
mkdir -p "$FORGE_TEST_PROJECT"

cat > "$FAKE_BIN/tea" <<'SH'
#!/usr/bin/env bash
# Log full argv (one invocation per line) plus an argv-by-argv dump for
# tests that need to assert on argument boundaries.
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

run_create_tea() {
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
    forge_issue_create "$@"
  )
}

reset_env() {
  unset REPOLENS_FAKE_TEA_RC REPOLENS_FAKE_TEA_LOG REPOLENS_FAKE_TEA_ARGV_DUMP
  unset REPOLENS_FAKE_TEA_STDOUT REPOLENS_FAKE_TEA_STDERR
  unset FORGE_PROJECT_PATH FORGE_REMOTE_NAME FORGE_TEA_LOGIN
}

body_file="$TMPDIR/body.md"
cat > "$body_file" <<'MD'
# Finding

```bash
echo "preserves backticks and newlines"
```

- bullet 1
- bullet 2
MD

# ---------------------------------------------------------------------------
# Group 1: tea success path — JSON parse + URL emission
# ---------------------------------------------------------------------------
echo "--- Group 1: tea success path ---"
echo ""

echo "Test 1: tea returns html_url JSON -> wrapper prints URL and exits 0"
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/7"}'
out="$(run_create_tea owner/repo 'My title' "$body_file" 2>/dev/null)"
rc=$?
assert_rc_zero "tea success returns 0" "$rc"
assert_eq "stdout is the html_url from tea JSON" \
  "https://gitea.example.com/owner/repo/issues/7" "$out"

echo ""
echo "Test 2: tea argv contains the project-path/remote target binding"
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
tea_log="$TMPDIR/t2-tea.log"
argv_dump="$TMPDIR/t2-argv.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_ARGV_DUMP="$argv_dump"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/1"}'
out="$(run_create_tea owner/repo 'My title' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
argv_content="$(cat "$argv_dump")"
assert_rc_zero "argv-contract create succeeds" "$rc"
assert_contains "tea is invoked with 'issues create'" "issues create" "$logged"
assert_contains "tea argv carries --repo project-path"  "--repo" "$logged"
assert_contains "tea argv carries the project path verbatim" \
  "<$FORGE_TEST_PROJECT>" "$argv_content"
assert_contains "tea argv carries --remote origin"   "--remote origin" "$logged"
assert_contains "tea argv carries --title <t>"       "--title" "$logged"
assert_contains "tea argv carries the title value"   "<My title>" "$argv_content"
assert_contains "tea argv carries --body-file <bf>"  "--body-file" "$logged"
assert_contains "tea argv carries the body file path" "<$body_file>" "$argv_content"
assert_not_contains "tea argv does not use the rejected --description-file flag" \
  "--description-file" "$logged"

echo ""
echo "Test 3: multiple labels are joined as a single --labels CSV (tea idiom)"
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
tea_log="$TMPDIR/t3-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/2"}'
out="$(run_create_tea owner/repo 'Title' "$body_file" 'audit:demo' 'severity:high' 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "create with labels succeeds" "$rc"
assert_contains "tea uses --labels (plural CSV form, not gh's --label)" \
  "--labels" "$logged"
assert_contains "first label appears in argv" "audit:demo" "$logged"
assert_contains "second label appears in argv" "severity:high" "$logged"
# tea joins multi-label as CSV. Reject the gh-style repeated-flag shape.
assert_not_contains "tea must not use gh's repeated --label flag form" \
  "--label audit:demo" "$logged"

# ---------------------------------------------------------------------------
# Group 2: tea failure semantics
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: tea failure semantics ---"
echo ""

echo "Test 4: tea exits non-zero -> wrapper returns 1 with warn (failure path)"
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
REPOLENS_FAKE_TEA_RC=7
REPOLENS_FAKE_TEA_STDERR='Gitea API unavailable'
err_file="$TMPDIR/t4.err"
out="$(run_create_tea owner/repo 'Failing title' "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "tea failure returns non-zero" "$rc"
assert_eq "stdout is empty on tea failure" "" "$out"
assert_contains "warn mentions tea failed" "tea failed" "$stderr_content"
assert_contains "warn mentions the repo" "owner/repo" "$stderr_content"

echo ""
echo "Test 5: tea returns valid JSON without an html_url -> wrapper returns 1"
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"unrelated":"shape"}'
err_file="$TMPDIR/t5.err"
out="$(run_create_tea owner/repo 'No URL' "$body_file" 2>"$err_file")"
rc=$?
assert_rc_nonzero "missing html_url is observable to callers" "$rc"
assert_eq "stdout is empty when no html_url" "" "$out"

# ---------------------------------------------------------------------------
# Group 3: target binding requirement
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: target binding requirement ---"
echo ""

echo "Test 6: missing FORGE_PROJECT_PATH and FORGE_TEA_LOGIN -> die before tea"
reset_env
tea_log="$TMPDIR/t6-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_create_tea owner/repo 'Title' "$body_file" 2>&1)"
rc=$?
assert_rc_nonzero "missing target binding exits non-zero" "$rc"
assert_contains "die message mentions target binding" "target binding" "$out"
assert_log_empty "missing target binding does not invoke tea" "$tea_log"

echo ""
echo "Test 7: FORGE_TEA_LOGIN fallback when project path is unavailable"
reset_env
FORGE_TEA_LOGIN="work-login"
tea_log="$TMPDIR/t7-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/3"}'
out="$(run_create_tea owner/repo 'Via login' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "FORGE_TEA_LOGIN fallback exits zero" "$rc"
assert_eq "FORGE_TEA_LOGIN fallback prints html_url" \
  "https://gitea.example.com/owner/repo/issues/3" "$out"
assert_contains "FORGE_TEA_LOGIN fallback uses owner/repo as --repo selector" \
  "--repo owner/repo" "$logged"
assert_contains "FORGE_TEA_LOGIN fallback passes --login <name>" \
  "--login work-login" "$logged"
assert_not_contains "FORGE_TEA_LOGIN fallback does not pass --remote" \
  "--remote" "$logged"

# ---------------------------------------------------------------------------
# Group 4: argv contract — labels-omitted and remote-name default
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 4: argv edge cases ---"
echo ""

echo "Test 8: when no labels are supplied, --labels is NOT in argv"
# tea rejects '--labels ""'; the implementation must drop the flag entirely.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
tea_log="$TMPDIR/t8-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/8"}'
out="$(run_create_tea owner/repo 'No labels here' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "create without labels succeeds" "$rc"
assert_not_contains "argv must not carry --labels when no labels were passed" \
  "--labels" "$logged"

echo ""
echo "Test 9: FORGE_REMOTE_NAME defaults to 'origin' when unset"
# Implementation uses \${FORGE_REMOTE_NAME:-origin}; a forge user that
# never sets FORGE_REMOTE_NAME must still get a working --remote flag.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
# Deliberately do not export FORGE_REMOTE_NAME
tea_log="$TMPDIR/t9-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/9"}'
out="$(run_create_tea owner/repo 'Default remote' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "create with unset FORGE_REMOTE_NAME succeeds" "$rc"
assert_contains "default remote name is 'origin'" "--remote origin" "$logged"

echo ""
echo "Test 10: tea stderr first line is folded into the warn diagnostic"
# On failure the wrapper captures stderr's first line and includes it via
# 'err=<first line>' so operators can see what tea was unhappy about.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
REPOLENS_FAKE_TEA_RC=22
REPOLENS_FAKE_TEA_STDERR='auth token expired'
err_file="$TMPDIR/t10.err"
out="$(run_create_tea owner/repo 'Auth fail' "$body_file" 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "tea auth failure returns non-zero" "$rc"
assert_contains "warn surfaces tea stderr first line" \
  "auth token expired" "$stderr_content"
assert_contains "warn includes tea exit code" "rc=22" "$stderr_content"

echo ""
echo "Test 11: empty-string labels are filtered from the CSV (no leading commas)"
# The labels loop must skip empty strings via [[ -n "\$lbl" ]] || continue.
# Otherwise an array with a leading empty entry would produce '--labels ,real-label'.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
tea_log="$TMPDIR/t11-tea.log"
argv_dump="$TMPDIR/t11-argv.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_ARGV_DUMP="$argv_dump"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/11"}'
out="$(run_create_tea owner/repo 'Mixed labels' "$body_file" '' 'severity:high' '' 'kind:bug' 2>/dev/null)"
rc=$?
argv_content="$(cat "$argv_dump")"
assert_rc_zero "create with mixed empty/non-empty labels succeeds" "$rc"
assert_contains "CSV value contains the first non-empty label" \
  "<severity:high,kind:bug>" "$argv_content"
# Reject leading comma — would happen if empty entries were not skipped.
assert_not_contains "no leading comma in CSV" \
  "<,severity:high" "$argv_content"

echo ""
echo "Test 12: custom FORGE_REMOTE_NAME passes through (not hardcoded 'origin')"
# Test 9 covers the unset-defaults-to-origin branch; this pins the
# other side of \${FORGE_REMOTE_NAME:-origin}: when the operator sets a
# non-default remote (e.g. 'upstream'), the wrapper must forward it.
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=upstream
tea_log="$TMPDIR/t12-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/12"}'
out="$(run_create_tea owner/repo 'Custom remote' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
assert_rc_zero "create with custom FORGE_REMOTE_NAME succeeds" "$rc"
assert_contains "tea argv carries --remote upstream (not origin)" \
  "--remote upstream" "$logged"
assert_not_contains "tea argv does not silently fall back to --remote origin" \
  "--remote origin" "$logged"

echo ""
echo "Test 13: FORGE_PROJECT_PATH takes precedence when FORGE_TEA_LOGIN is also set"
# The target-binding cascade in the implementation checks PROJECT_PATH
# first; the LOGIN branch is the fallback. A user who has both env vars
# exported must get the project-path/remote shape (not the login shape).
reset_env
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME=origin
FORGE_TEA_LOGIN="should-be-ignored"
tea_log="$TMPDIR/t13-tea.log"
argv_dump="$TMPDIR/t13-argv.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_ARGV_DUMP="$argv_dump"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='{"html_url":"https://gitea.example.com/owner/repo/issues/13"}'
out="$(run_create_tea owner/repo 'Precedence check' "$body_file" 2>/dev/null)"
rc=$?
logged="$(cat "$tea_log")"
argv_content="$(cat "$argv_dump")"
assert_rc_zero "create with both env vars succeeds" "$rc"
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
