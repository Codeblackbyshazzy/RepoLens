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

# shellcheck disable=SC2329 # Helpers are invoked indirectly by the test harness.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/android-deploy-log-sanitization.XXXXXX")"
CREATED_LOG_DIRS=()

_cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMPROOT" 2>/dev/null || true
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
  echo "  FAIL: $1${2:+ ($2)}"
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  [[ "$haystack" == *"$needle"* ]] && record_pass "$desc" || record_fail "$desc" "expected to contain: $needle"
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  [[ "$haystack" != *"$needle"* ]] && record_pass "$desc" || record_fail "$desc" "unexpected content: $needle"
}

assert_file_equals() {
  local desc="$1" expected_file="$2" actual_file="$3"
  if cmp -s "$expected_file" "$actual_file"; then
    record_pass "$desc"
  else
    record_fail "$desc" "file contents differ"
  fi
}

record_run_id() {
  local log_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null | head -1 | awk '{print $3}' || true)"
  if [[ -n "${run_id:-}" ]]; then
    CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi
}

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
CODEX_APK_PATH_LOG="$TMPDIR/codex-apk-path.log"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf '%s' "${REPOLENS_ANDROID_APK_PATH:-}" > "${REPOLENS_CODEX_APK_PATH_LOG:?}"
printf '%s\n' DONE
SH
chmod +x "$FAKE_BIN/codex"
export PATH="$FAKE_BIN:$PATH"
export REPOLENS_CODEX_APK_PATH_LOG="$CODEX_APK_PATH_LOG"

cat > "$FAKE_BIN/aapt" <<'SH'
#!/usr/bin/env bash
printf "%s\n" "package: name='com.example.sanitized' versionCode='1' versionName='1.0'"
SH
chmod +x "$FAKE_BIN/aapt"

run_repolens() {
  local project="$1" log_file="$2"
  shift 2

  : > "$log_file"
  set +e
  bash "$REPOLENS" \
    --project "$project" \
    --agent codex \
    --mode deploy \
    --local \
    --yes \
    --focus apk-overview \
    "$@" \
    >"$log_file" 2>&1
  local rc=$?
  set -e
  record_run_id "$log_file"
  return "$rc"
}

echo ""
echo "=== Test Suite: Android deploy log APK path sanitization (issue #190) ==="
echo ""

CONTROL_NAME="release"$'\n'"[ERROR] forged"$'\e'"[31m.apk"
SANITIZED_NAME="release?[ERROR] forged?[31m.apk"

echo "Test 1: direct APK deploy logs sanitize a control-character filename"
DIRECT_DIR="$TMPDIR/direct"
mkdir -p "$DIRECT_DIR"
DIRECT_APK="$DIRECT_DIR/$CONTROL_NAME"
DIRECT_EXPECTED="$TMPDIR/direct-expected-path"
: > "$DIRECT_APK"
printf '%s' "$DIRECT_APK" > "$DIRECT_EXPECTED"

DIRECT_LOG="$TMPDIR/direct.log"
rm -f "$CODEX_APK_PATH_LOG"
run_repolens "$DIRECT_APK" "$DIRECT_LOG" || true
direct_out="$(cat "$DIRECT_LOG")"

assert_contains "direct deploy log includes sanitized APK filename" "$SANITIZED_NAME" "$direct_out"
assert_not_contains "direct deploy log does not contain forged error line" $'\n[ERROR] forged' "$direct_out"
assert_not_contains "direct deploy log does not contain raw ANSI escape" $'\e[31m' "$direct_out"
assert_file_equals "direct deploy preserves raw APK path for agent environment" "$DIRECT_EXPECTED" "$CODEX_APK_PATH_LOG"

echo ""
echo "Test 2: post-build rediscovery logs sanitize a control-character filename"
SOURCE_DIR="$TMPDIR/source"
mkdir -p "$SOURCE_DIR/app/build/outputs/apk/debug"
printf '%s\n' 'plugins { id "com.android.application" }' > "$SOURCE_DIR/build.gradle"
BUILT_APK="$SOURCE_DIR/app/build/outputs/apk/debug/$CONTROL_NAME"
BUILT_EXPECTED="$TMPDIR/built-expected-path"
BUILD_ENV="$TMPDIR/build.bashenv"
printf '%s' "$BUILT_APK" > "$BUILT_EXPECTED"
cat > "$BUILD_ENV" <<EOF
build_android_apk() {
  mkdir -p "$SOURCE_DIR/app/build/outputs/apk/debug"
  : > "$BUILT_APK"
  printf '%s\n' "$BUILT_APK"
}
EOF

BUILD_LOG="$TMPDIR/build.log"
rm -f "$CODEX_APK_PATH_LOG"
_old_bash_env="${BASH_ENV-}"
_old_bash_env_set="${BASH_ENV+x}"
export BASH_ENV="$BUILD_ENV"
run_repolens "$SOURCE_DIR" "$BUILD_LOG" --build-android-apk || true
if [[ -n "$_old_bash_env_set" ]]; then
  export BASH_ENV="$_old_bash_env"
else
  unset BASH_ENV
fi
unset _old_bash_env _old_bash_env_set
build_out="$(cat "$BUILD_LOG")"

assert_contains "post-build deploy log includes sanitized APK filename" "$SANITIZED_NAME" "$build_out"
assert_not_contains "post-build deploy log does not contain forged error line" $'\n[ERROR] forged' "$build_out"
assert_not_contains "post-build deploy log does not contain raw ANSI escape" $'\e[31m' "$build_out"
assert_file_equals "post-build deploy preserves raw APK path for agent environment" "$BUILT_EXPECTED" "$CODEX_APK_PATH_LOG"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
