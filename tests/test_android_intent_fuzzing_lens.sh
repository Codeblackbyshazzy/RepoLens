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

# Tests for issue #103 - Android intent fuzzing lens.
#
# Behavioural contract:
#   - android/intent-fuzzing exists and is registered in config/domains.json.
#   - The Android base prompt reconciles the read-only safety model with this
#     lens's narrow active IPC exception.
#   - The lens covers exported-component fuzzing through am start, am broadcast,
#     and read-only content query probes gated on ANDROID_HAS_DEVICE.
#   - Examples avoid destructive device/app/provider mutation commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/intent-fuzzing.md"
ANDROID_BASE="$SCRIPT_DIR/prompts/_base/android.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

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
  echo "  FAIL: $1"
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (missing '$needle')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (should not contain '$needle')"
  fi
}

echo ""
echo "=== Test Suite: Android intent fuzzing lens (issue #103) ==="
echo ""

echo "Test 1: lens file and Android base prompt exist"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "intent-fuzzing lens file exists"
else
  record_fail "intent-fuzzing lens file exists"
fi

if [[ -f "$ANDROID_BASE" ]]; then
  record_pass "android base prompt exists"
else
  record_fail "android base prompt exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

base_content=""
if [[ -f "$ANDROID_BASE" ]]; then
  base_content="$(cat "$ANDROID_BASE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: intent-fuzzing" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: Intent Fuzzing Auditor" "$lens_content"
assert_contains "role frontmatter" "role: Android IPC Fuzzing Specialist" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses[]' "$DOMAINS_FILE")"
assert_contains "registered android lens list includes intent-fuzzing" "intent-fuzzing" "$android_lenses"

echo ""
echo "Test 4: Android base prompt has a narrow active IPC exception"
assert_contains "base names the intent-fuzzing exception" 'android/intent-fuzzing' "$base_content"
assert_contains "base gates exception on device availability" '{{ANDROID_HAS_DEVICE}}' "$base_content"
assert_contains "base requires authorized active Android IPC fuzzing" "authorized for active Android IPC fuzzing" "$base_content"
assert_contains "base permits activity launches only for this exception" 'adb shell am start' "$base_content"
assert_contains "base permits receiver broadcasts only for this exception" 'adb shell am broadcast' "$base_content"
assert_contains "base permits read-only provider query only for this exception" 'adb shell content query' "$base_content"
assert_contains "base requires stopping on stateful side effects" "stop active probing immediately" "$base_content"
assert_contains "base keeps destructive mutations forbidden" "does not permit any other active or mutating device/app operation" "$base_content"
assert_contains "base allows active probe evidence in observed state" "the exact active IPC probe commands permitted by the exception above" "$base_content"
assert_contains "base allows active probe remediation verification" "permitted \`android/intent-fuzzing\` active IPC probe command(s)" "$base_content"

echo ""
echo "Test 5: lens aligns with the base exception and device gate"
assert_contains "lens references base-approved active probes" "base-approved active probes" "$lens_content"
assert_contains "lens says probes are only under base exception" "Active probes are allowed only under the base Android prompt" "$lens_content"
assert_contains "lens lists only active device commands" "The only active device commands this lens may use" "$lens_content"
assert_contains "lens gates active probes on Android device availability" '{{ANDROID_HAS_DEVICE}}' "$lens_content"
assert_contains "lens skips cleanly when no device is connected" "intent-fuzzing dynamic probes skipped" "$lens_content"
assert_contains "lens requires authorized audit context" "already-authorized Android audit context" "$lens_content"
assert_contains "lens requires stopping on stateful side effects" "stop active probing immediately" "$lens_content"

echo ""
echo "Test 6: issue intent-fuzzing risk areas are covered"
for term in \
  "exported-component fuzzing" \
  "runtime crashes" \
  "auth bypasses" \
  "malformed deeplink" \
  "ContentProvider" \
  "provider disclosure" \
  "BroadcastReceiver" \
  "broadcast spoofing" \
  "Sticky broadcast" \
  "path traversal" \
  "intent redirection" \
  "Mutable PendingIntent" \
  "FLAG_MUTABLE" \
  "FLAG_IMMUTABLE"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: investigation commands use safe Android variables and private scratch"
assert_contains "assigns runtime APK path to local variable" 'apk_path=${ANDROID_APK_PATH:?ANDROID_APK_PATH is required}' "$lens_content"
assert_contains "checks quoted APK path exists" '[ -f "$apk_path" ]' "$lens_content"
assert_contains "assigns package name to local variable" 'package_name=${ANDROID_PACKAGE_NAME:-unknown}' "$lens_content"
assert_contains "sets restrictive umask for scratch tree" 'umask 077' "$lens_content"
assert_contains "creates unique scratch directory" 'scratch_dir="$(mktemp -d)"' "$lens_content"
assert_contains "places apktool output under scratch tree" 'apktool_out="$scratch_dir/apktool"' "$lens_content"
assert_contains "places jadx output under scratch tree" 'jadx_out="$scratch_dir/jadx"' "$lens_content"
assert_contains "places logcat output under scratch tree" 'logcat_out="$scratch_dir/logcat"' "$lens_content"
assert_contains "cleans scratch output" 'rm -rf -- "$scratch_dir"' "$lens_content"
assert_not_contains "does not use any hard-coded tmp directory" "/tmp/" "$lens_content"

echo ""
echo "Test 8: active examples are limited to required IPC probes"
assert_contains "includes activity start probe" 'adb shell am start' "$lens_content"
assert_contains "includes receiver broadcast probe" 'adb shell am broadcast' "$lens_content"
assert_contains "includes read-only provider query probe" 'adb shell content query --uri' "$lens_content"
assert_not_contains "does not use shorthand adb am start" 'adb am start' "$lens_content"
assert_not_contains "does not use shorthand adb am broadcast" 'adb am broadcast' "$lens_content"

echo ""
echo "Test 9: examples avoid destructive device, app, and provider mutation commands"
for forbidden in \
  "adb install" \
  "pm clear" \
  "am force-stop" \
  "settings put" \
  "adb push" \
  "input tap" \
  "adb logcat -c" \
  "adb shell content insert" \
  "adb shell content update" \
  "adb shell content delete" \
  "content insert" \
  "content update" \
  "content delete"; do
  assert_not_contains "does not mention $forbidden" "$forbidden" "$lens_content"
done

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
