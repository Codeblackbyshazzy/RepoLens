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

# Tests for issue #188 - explicit deploy target resolution.
#
# Behavioural contract:
#   - repolens.sh accepts --deploy-target auto|server|android in deploy mode.
#   - --deploy-target is rejected outside deploy mode.
#   - invalid deploy target values fail with a clear allowed-values error.
#   - explicit server remains a live-server deploy target even when Android
#     APK/source markers are present.
#   - explicit android requires a discovered APK or shallow Android source
#     marker, otherwise exits 0 with the issue-specified no-target message.
#   - default auto chooses Android only for a discovered APK or shallow source
#     marker, and otherwise falls back to server deployment lenses.
#
# The tests drive the public CLI in --dry-run mode with a fake agent binary.
# They do not call internal helper functions directly and never invoke a real
# model.

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected='$expected' actual='$actual')"
  fi
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

assert_file_absent() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (file unexpectedly exists: $path)"
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

SOURCE_DIR="$TMPDIR/source-target"
mkdir -p "$SOURCE_DIR"
cat > "$SOURCE_DIR/build.gradle" <<'EOF'
android { compileSdkVersion 34 }
EOF
GRADLEW_SENTINEL="$TMPDIR/gradlew_was_executed.txt"
cat > "$SOURCE_DIR/gradlew" <<EOF
#!/usr/bin/env bash
echo "gradlew should not run during deploy target resolution" > "$GRADLEW_SENTINEL"
exit 0
EOF
chmod +x "$SOURCE_DIR/gradlew"

SERVER_WITH_ANDROID_MARKERS_DIR="$TMPDIR/server-with-android-markers"
mkdir -p "$SERVER_WITH_ANDROID_MARKERS_DIR/app/build/outputs/apk/debug"
: > "$SERVER_WITH_ANDROID_MARKERS_DIR/app/build/outputs/apk/debug/app-debug.apk"
cat > "$SERVER_WITH_ANDROID_MARKERS_DIR/build.gradle" <<'EOF'
android { compileSdkVersion 34 }
EOF

NO_ANDROID_TARGET_MSG="No APK found and project does not appear to be an Android source tree (no build.gradle / gradlew). Either supply a project containing an APK, an Android source tree, or use --mode deploy with a server target."

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
echo "=== Test Suite: deploy target resolution (issue #188) ==="
echo ""

# ===========================================================================
# Test 1: --deploy-target is deploy-mode only
# ===========================================================================
echo "Test 1: --deploy-target is rejected outside deploy mode"
LOG1="$TMPDIR/run1.log"
run_repolens "$SCRIPT_DIR" "$LOG1" \
  --mode audit \
  --local \
  --dry-run \
  --yes \
  --deploy-target server || rc1=$?
rc1="${rc1:-0}"
out1="$(cat "$LOG1")"

assert_rc_nonzero "--deploy-target outside deploy exits non-zero" "$rc1"
assert_contains "--deploy-target outside deploy reports deploy-mode requirement" \
  "--deploy-target requires --mode deploy" "$out1"

# ===========================================================================
# Test 2: invalid values are rejected clearly
# ===========================================================================
echo ""
echo "Test 2: invalid --deploy-target values are rejected"
LOG2="$TMPDIR/run2.log"
run_dry_deploy "$PLAIN_DIR" "$LOG2" --deploy-target banana || rc2=$?
rc2="${rc2:-0}"
out2="$(cat "$LOG2")"

assert_rc_nonzero "invalid deploy target exits non-zero" "$rc2"
assert_contains "invalid deploy target reports allowed values" \
  "Invalid --deploy-target: banana (expected auto, server, or android)" "$out2"

# ===========================================================================
# Test 3: explicit server ignores Android-looking project contents
# ===========================================================================
echo ""
echo "Test 3: explicit server resolves deployment lenses even with Android markers"
LOG3="$TMPDIR/run3.log"
run_dry_deploy "$SERVER_WITH_ANDROID_MARKERS_DIR" "$LOG3" --deploy-target server || rc3=$?
rc3="${rc3:-0}"
out3="$(cat "$LOG3")"

assert_rc_zero "explicit server run exits zero" "$rc3"
assert_contains "explicit server resolves deployment/* lenses" "deployment/" "$out3"
assert_not_contains "explicit server does not resolve android/* lenses" "android/" "$out3"
assert_contains "explicit server reaches dry-run completion" "Dry run complete" "$out3"

# ===========================================================================
# Test 4: explicit android exits 0 with exact no-target message on plain dirs
# ===========================================================================
echo ""
echo "Test 4: explicit android with no APK or source marker exits 0 with message"
LOG4="$TMPDIR/run4.log"
run_dry_deploy "$PLAIN_DIR" "$LOG4" --deploy-target android || rc4=$?
rc4="${rc4:-0}"
out4="$(cat "$LOG4")"

assert_rc_zero "explicit android no-target path exits zero" "$rc4"
assert_eq "explicit android no-target message is exact" "$NO_ANDROID_TARGET_MSG" "$out4"
assert_not_contains "explicit android no-target does not resolve deployment lenses" "deployment/" "$out4"
assert_not_contains "explicit android no-target does not resolve android lenses" "android/" "$out4"
assert_not_contains "explicit android no-target exits before dry-run completion" "Dry run complete" "$out4"

# ===========================================================================
# Test 5: explicit android accepts an existing APK
# ===========================================================================
echo ""
echo "Test 5: explicit android with existing APK resolves Android lenses"
LOG5="$TMPDIR/run5.log"
run_dry_deploy "$APK_DIR" "$LOG5" --deploy-target android || rc5=$?
rc5="${rc5:-0}"
out5="$(cat "$LOG5")"

assert_rc_zero "explicit android APK run exits zero" "$rc5"
assert_contains "explicit android APK resolves android/* lenses" "android/" "$out5"
assert_not_contains "explicit android APK does not resolve deployment/* lenses" "deployment/" "$out5"
assert_contains "explicit android APK reaches dry-run completion" "Dry run complete" "$out5"

# ===========================================================================
# Test 6: explicit android accepts shallow source markers without building
# ===========================================================================
echo ""
echo "Test 6: explicit android with shallow source marker resolves Android lenses"
LOG6="$TMPDIR/run6.log"
rm -f "$GRADLEW_SENTINEL"
run_dry_deploy "$SOURCE_DIR" "$LOG6" --deploy-target android || rc6=$?
rc6="${rc6:-0}"
out6="$(cat "$LOG6")"

assert_rc_zero "explicit android source-marker run exits zero" "$rc6"
assert_contains "explicit android source marker resolves android/* lenses" "android/" "$out6"
assert_not_contains "explicit android source marker does not resolve deployment/* lenses" "deployment/" "$out6"
assert_contains "explicit android source marker reaches dry-run completion" "Dry run complete" "$out6"
assert_file_absent "explicit android source marker does not execute gradlew during dry-run" "$GRADLEW_SENTINEL"

# ===========================================================================
# Test 7: default auto selects Android for APKs and shallow source markers
# ===========================================================================
echo ""
echo "Test 7: default auto selects Android when APK or source marker is present"
LOG7A="$TMPDIR/run7a.log"
run_dry_deploy "$APK_DIR" "$LOG7A" || rc7a=$?
rc7a="${rc7a:-0}"
out7a="$(cat "$LOG7A")"

assert_rc_zero "auto APK run exits zero" "$rc7a"
assert_contains "auto APK resolves android/* lenses" "android/" "$out7a"
assert_not_contains "auto APK does not resolve deployment/* lenses" "deployment/" "$out7a"

LOG7B="$TMPDIR/run7b.log"
rm -f "$GRADLEW_SENTINEL"
run_dry_deploy "$SOURCE_DIR" "$LOG7B" || rc7b=$?
rc7b="${rc7b:-0}"
out7b="$(cat "$LOG7B")"

assert_rc_zero "auto source-marker run exits zero" "$rc7b"
assert_contains "auto source marker resolves android/* lenses" "android/" "$out7b"
assert_not_contains "auto source marker does not resolve deployment/* lenses" "deployment/" "$out7b"
assert_file_absent "auto source marker does not execute gradlew during dry-run" "$GRADLEW_SENTINEL"

# ===========================================================================
# Test 8: default auto falls back to server for plain non-git directories
# ===========================================================================
echo ""
echo "Test 8: default auto falls back to server when no Android target exists"
LOG8="$TMPDIR/run8.log"
run_dry_deploy "$PLAIN_DIR" "$LOG8" || rc8=$?
rc8="${rc8:-0}"
out8="$(cat "$LOG8")"

assert_rc_zero "auto plain directory run exits zero" "$rc8"
assert_contains "auto plain directory resolves deployment/* lenses" "deployment/" "$out8"
assert_not_contains "auto plain directory does not resolve android/* lenses" "android/" "$out8"
assert_contains "auto plain directory reaches dry-run completion" "Dry run complete" "$out8"

# ===========================================================================
# Test 9: explicit auto is accepted and direct APKs can be forced to server
# ===========================================================================
echo ""
echo "Test 9: explicit auto and direct APK server override"
LOG9A="$TMPDIR/run9a.log"
run_dry_deploy "$APK_DIR" "$LOG9A" --deploy-target auto || rc9a=$?
rc9a="${rc9a:-0}"
out9a="$(cat "$LOG9A")"

assert_rc_zero "explicit auto APK run exits zero" "$rc9a"
assert_contains "explicit auto APK resolves android/* lenses" "android/" "$out9a"
assert_not_contains "explicit auto APK does not resolve deployment/* lenses" "deployment/" "$out9a"

DIRECT_APK="$APK_DIR/app/build/outputs/apk/debug/app-debug.apk"
LOG9B="$TMPDIR/run9b.log"
run_dry_deploy "$DIRECT_APK" "$LOG9B" --deploy-target server || rc9b=$?
rc9b="${rc9b:-0}"
out9b="$(cat "$LOG9B")"

assert_rc_zero "direct APK with explicit server exits zero" "$rc9b"
assert_contains "direct APK with explicit server resolves deployment/* lenses" "deployment/" "$out9b"
assert_not_contains "direct APK with explicit server does not resolve android/* lenses" "android/" "$out9b"
assert_contains "direct APK with explicit server reaches dry-run completion" "Dry run complete" "$out9b"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
