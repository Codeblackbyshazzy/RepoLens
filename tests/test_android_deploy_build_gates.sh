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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"
mkdir -p "$SCRIPT_DIR/tests/.tmp"
TMPDIR="$(mktemp -d "$SCRIPT_DIR/tests/.tmp/android-deploy-build-gates.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
TOTAL=0

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

assert_file_absent() {
  local desc="$1" path="$2"
  [[ ! -e "$path" ]] && record_pass "$desc" || record_fail "$desc" "unexpected file: $path"
}

assert_file_present() {
  local desc="$1" path="$2"
  [[ -e "$path" ]] && record_pass "$desc" || record_fail "$desc" "missing file: $path"
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  [[ "$haystack" == *"$needle"* ]] && record_pass "$desc" || record_fail "$desc" "expected to contain: $needle"
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  [[ "$haystack" != *"$needle"* ]] && record_pass "$desc" || record_fail "$desc" "unexpected content: $needle"
}

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
CODEX_ENV_LOG="$TMPDIR/codex-env.log"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
{
  printf 'PROJECT_PATH=%s\n' "${PROJECT_PATH:-}"
  printf 'REPOLENS_DEPLOY_TARGET_KIND=%s\n' "${REPOLENS_DEPLOY_TARGET_KIND:-}"
  printf 'REPOLENS_ANDROID_APK_PATH=%s\n' "${REPOLENS_ANDROID_APK_PATH:-}"
} >> "${REPOLENS_CODEX_ENV_LOG:?}"
printf '%s\n' DONE
SH
chmod +x "$FAKE_BIN/codex"
export PATH="$FAKE_BIN:$PATH"
export REPOLENS_CODEX_ENV_LOG="$CODEX_ENV_LOG"

ANDROID_SRC="$TMPDIR/android-src"
mkdir -p "$ANDROID_SRC/app/build/outputs/apk/debug"
printf '%s\n' 'plugins { id "com.android.application" }' > "$ANDROID_SRC/build.gradle"
GRADLEW_SENTINEL="$TMPDIR/gradlew-ran"
cat > "$ANDROID_SRC/gradlew" <<EOF
#!/usr/bin/env bash
echo ran > "$GRADLEW_SENTINEL"
exit 0
EOF
chmod +x "$ANDROID_SRC/gradlew"

BUILD_CALLS="$TMPDIR/build-calls.log"
BUILT_APK="$ANDROID_SRC/app/build/outputs/apk/debug/app-debug.apk"
BUILD_ENV="$TMPDIR/build-success.bashenv"
cat > "$BUILD_ENV" <<EOF
build_android_apk() {
  printf 'build:%s\n' "\$1" >> "$BUILD_CALLS"
  : > "$BUILT_APK"
  printf '%s\n' "$BUILT_APK"
}
EOF

FAIL_ENV="$TMPDIR/build-failure.bashenv"
cat > "$FAIL_ENV" <<EOF
build_android_apk() {
  printf 'build:%s\n' "\$1" >> "$BUILD_CALLS"
  printf '%s\n' 'GRADLE STDERR MARKER' >&2
  return 37
}
EOF

run_pty() {
  local input="$1" env_file="$2" log_file="$3"
  shift 3
  : > "$log_file"
  local old_bash_env="${BASH_ENV-}" old_bash_env_set="${BASH_ENV+x}"
  export BASH_ENV="$env_file"
  set +e
  printf '%b' "$input" | script -qfec "bash \"$REPOLENS\" --project \"$ANDROID_SRC\" --agent codex --mode deploy --local --build-android-apk --focus apk-overview $*" "$log_file" >/dev/null 2>&1
  local rc=$?
  set -e
  if [[ -n "$old_bash_env_set" ]]; then
    export BASH_ENV="$old_bash_env"
  else
    unset BASH_ENV
  fi
  return "$rc"
}

run_dry() {
  local log_file="$1"
  : > "$log_file"
  local old_bash_env="${BASH_ENV-}" old_bash_env_set="${BASH_ENV+x}"
  export BASH_ENV="$BUILD_ENV"
  set +e
  bash "$REPOLENS" --project "$ANDROID_SRC" --agent codex --mode deploy --local --dry-run --yes --build-android-apk >"$log_file" 2>&1
  local rc=$?
  set -e
  if [[ -n "$old_bash_env_set" ]]; then
    export BASH_ENV="$old_bash_env"
  else
    unset BASH_ENV
  fi
  return "$rc"
}

echo ""
echo "=== Test Suite: Android deploy build gates (issue #189) ==="
echo ""

LOG_DRY="$TMPDIR/dry.log"
rm -f "$BUILD_CALLS" "$GRADLEW_SENTINEL" "$BUILT_APK"
run_dry "$LOG_DRY" || true
dry_out="$(cat "$LOG_DRY")"
assert_contains "dry-run completes without building" "Dry run complete" "$dry_out"
assert_file_absent "dry-run does not call build_android_apk" "$BUILD_CALLS"
assert_file_absent "dry-run does not execute gradlew" "$GRADLEW_SENTINEL"

LOG_AUTH_ABORT="$TMPDIR/auth-abort.log"
rm -f "$BUILD_CALLS" "$BUILT_APK"
run_pty 'n\n' "$BUILD_ENV" "$LOG_AUTH_ABORT" || true
auth_abort_out="$(cat "$LOG_AUTH_ABORT")"
assert_contains "authorization prompt appears before build" "Authorization Required" "$auth_abort_out"
assert_file_absent "authorization abort does not build" "$BUILD_CALLS"

LOG_RUN_ABORT="$TMPDIR/run-abort.log"
rm -f "$BUILD_CALLS" "$BUILT_APK"
run_pty 'y\nn\n' "$BUILD_ENV" "$LOG_RUN_ABORT" || true
run_abort_out="$(cat "$LOG_RUN_ABORT")"
assert_contains "normal confirmation appears before build" "Proceed? [y/N]" "$run_abort_out"
assert_file_absent "normal confirmation abort does not build" "$BUILD_CALLS"

LOG_SUCCESS="$TMPDIR/success.log"
rm -f "$BUILD_CALLS" "$BUILT_APK" "$CODEX_ENV_LOG"
run_pty 'y\ny\n' "$BUILD_ENV" "$LOG_SUCCESS" || true
success_env="$(cat "$CODEX_ENV_LOG" 2>/dev/null || true)"
assert_file_present "accepted gates invoke build helper" "$BUILD_CALLS"
assert_file_present "accepted gates create rediscoverable APK" "$BUILT_APK"
assert_contains "agent sees android deploy target kind" "REPOLENS_DEPLOY_TARGET_KIND=android" "$success_env"
assert_contains "agent sees rediscovered APK path" "REPOLENS_ANDROID_APK_PATH=$BUILT_APK" "$success_env"
assert_contains "agent PROJECT_PATH remains source directory" "PROJECT_PATH=$ANDROID_SRC" "$success_env"

LOG_FAIL="$TMPDIR/fail.log"
rm -f "$BUILD_CALLS" "$BUILT_APK" "$CODEX_ENV_LOG"
run_pty 'y\ny\n' "$FAIL_ENV" "$LOG_FAIL" || true
fail_out="$(cat "$LOG_FAIL")"
assert_contains "build failure preserves helper stderr" "GRADLE STDERR MARKER" "$fail_out"
assert_contains "build failure reports real status" "Android APK build failed with status 37" "$fail_out"
assert_file_absent "build failure stops before agent execution" "$CODEX_ENV_LOG"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
