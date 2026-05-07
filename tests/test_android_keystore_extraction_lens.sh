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

# Tests for issue #106 - Android KeyStore and secure-storage lens.
#
# Behavioural contract:
#   - android/keystore-extraction exists and is registered in config/domains.json.
#   - The prompt covers KeyStore, EncryptedSharedPreferences, SQLCipher/Realm,
#     biometric strength, and backup/exfiltration risks named in the issue.
#   - Static examples use safe runtime variables and private scratch output.
#   - Dynamic work is device-gated, read-only, and attach-only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/keystore-extraction.md"
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
echo "=== Test Suite: Android KeyStore and secure-storage lens (issue #106) ==="
echo ""

echo "Test 1: lens file exists"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "keystore-extraction lens file exists"
else
  record_fail "keystore-extraction lens file exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: keystore-extraction" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: Mobile Secure Storage Auditor" "$lens_content"
assert_contains "role frontmatter" "role: Android KeyStore & Secure Storage Specialist" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses[]' "$DOMAINS_FILE")"
assert_contains "registered android lens list includes keystore-extraction" "keystore-extraction" "$android_lenses"

echo ""
echo "Test 4: issue secure-storage risks are covered"
for term in \
  "KeyStore.getInstance" \
  "AndroidKeyStore" \
  "KeyGenParameterSpec" \
  "MasterKey" \
  "EncryptedSharedPreferences" \
  "SharedPreferences" \
  "SQLCipher" \
  "Realm" \
  "setUserAuthenticationRequired" \
  "setInvalidatedByBiometricEnrollment" \
  "setIsStrongBoxBacked" \
  "BiometricManager" \
  "BIOMETRIC_WEAK" \
  "android:allowBackup" \
  "android:fullBackupContent" \
  "android:dataExtractionRules"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 5: investigation commands use safe Android variables"
assert_contains "assigns runtime APK path to local variable" 'apk_path=${ANDROID_APK_PATH:?ANDROID_APK_PATH is required}' "$lens_content"
assert_contains "checks quoted APK path exists" '[ -f "$apk_path" ]' "$lens_content"
assert_contains "assigns package name to local variable" 'package_name=${ANDROID_PACKAGE_NAME:-unknown}' "$lens_content"
assert_contains "gates dynamic work on Android device availability" '{{ANDROID_HAS_DEVICE}}' "$lens_content"
assert_contains "uses quoted APK variable for badging" 'aapt dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for aapt2 badging" 'aapt2 dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for manifest xmltree" 'aapt dump xmltree "$apk_path" AndroidManifest.xml' "$lens_content"
assert_contains "uses quoted APK variable for unzip inventory" 'unzip -l "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for DEX streaming" 'unzip -p "$apk_path" classes.dex | strings' "$lens_content"
assert_contains "uses quoted APK variable for apktool" 'apktool d -f "$apk_path" -o "$apktool_out"' "$lens_content"
assert_contains "uses quoted APK variable for jadx" 'jadx -d "$jadx_out" "$apk_path"' "$lens_content"
assert_contains "uses quoted package name for device inventory" 'adb shell dumpsys package "$package_name" | head -200' "$lens_content"
assert_not_contains "does not quote template APK path in commands" '"{{ANDROID_APK_PATH}}"' "$lens_content"

echo ""
echo "Test 6: decoded, backup, and hook output uses private scratch directory"
assert_contains "sets restrictive umask for scratch tree" 'umask 077' "$lens_content"
assert_contains "creates unique scratch directory" 'scratch_dir="$(mktemp -d)"' "$lens_content"
assert_contains "places apktool output under scratch tree" 'apktool_out="$scratch_dir/apktool"' "$lens_content"
assert_contains "places jadx output under scratch tree" 'jadx_out="$scratch_dir/jadx"' "$lens_content"
assert_contains "places backup output under scratch tree" 'backup_file="$scratch_dir/backup.ab"' "$lens_content"
assert_contains "places hook script under scratch tree" 'hook_js="$scratch_dir/keystore-extraction-observe.js"' "$lens_content"
assert_contains "cleans scratch output" 'rm -rf -- "$scratch_dir"' "$lens_content"
assert_not_contains "does not use any hard-coded tmp directory" "/tmp/" "$lens_content"

echo ""
echo "Test 7: dynamic work is read-only and attach-only"
assert_contains "uses read-only adb device inventory" "adb devices -l" "$lens_content"
assert_contains "uses run-as for inventory only" 'adb shell run-as "$package_name" ls -la databases/ files/ shared_prefs/' "$lens_content"
assert_contains "keeps adb backup under scratch" 'adb backup -f "$backup_file" "$package_name"' "$lens_content"
assert_contains "checks for already-running process" 'frida-ps -U | grep -F "$package_name"' "$lens_content"
assert_contains "uses attach-only frida" 'frida -U -n "$package_name" -l "$hook_js"' "$lens_content"
for forbidden in \
  "frida -U -f" \
  "adb install" \
  "adb push" \
  "pm clear" \
  "am force-stop" \
  "settings put" \
  "input tap"; do
  assert_not_contains "does not mention $forbidden" "$forbidden" "$lens_content"
done

echo ""
echo "Test 8: reporting requires evidence and redaction"
assert_contains "rejects generic findings" 'Do not file generic "secure storage could be stronger" issues.' "$lens_content"
assert_contains "rejects setup-only backup findings" "is a setup limitation, not a vulnerability" "$lens_content"
assert_contains "requires redaction of full values" "Redact full tokens" "$lens_content"
assert_contains "requires read-only verification command" "read-only verification command" "$lens_content"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
