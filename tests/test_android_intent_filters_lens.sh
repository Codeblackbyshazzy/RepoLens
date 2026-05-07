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

# Tests for issue #98 - Android intent-filter and deeplink lens.
#
# Behavioural contract:
#   - android/intent-filters exists and is registered in config/domains.json.
#   - The prompt covers the deeplink, App Links, custom scheme, task hijacking,
#     sensitive exposure, file scheme, WebView sink, and intent-redirection
#     risks named in the issue.
#   - Shell examples use the exported runtime APK path variable through a
#     local shell variable, not fixed shared decode paths.
#   - Examples remain read-only and avoid active device/app mutation commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/intent-filters.md"
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
echo "=== Test Suite: Android intent-filter and deeplink lens (issue #98) ==="
echo ""

echo "Test 1: lens file exists"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "intent-filters lens file exists"
else
  record_fail "intent-filters lens file exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: intent-filters" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: Intent Filter & Deeplink Auditor" "$lens_content"
assert_contains "role frontmatter" "role: Android Intent & App Link Specialist" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses[]' "$DOMAINS_FILE")"
assert_contains "registered android lens list includes intent-filters" "intent-filters" "$android_lenses"

echo ""
echo "Test 4: issue intent-filter risks are covered"
for risk in \
  "android:autoVerify" \
  "assetlinks.json" \
  "sha256_cert_fingerprints" \
  "custom schemes" \
  "android:taskAffinity" \
  "singleTask" \
  "singleInstance" \
  "android:allowTaskReparenting" \
  "android.intent.action.VIEW" \
  "android:scheme=\"file\"" \
  "WebView.loadUrl" \
  "android:permission" \
  "android:exported" \
  "android:host=\"*\"" \
  "getParcelableExtra" \
  "startActivity" \
  "PendingIntent" \
  "Runtime.exec" \
  "ProcessBuilder"; do
  assert_contains "covers $risk" "$risk" "$lens_content"
done

echo ""
echo "Test 5: investigation commands use shell-safe runtime APK variable"
assert_contains "assigns runtime APK path to local variable" 'apk_path=${ANDROID_APK_PATH:?ANDROID_APK_PATH is required}' "$lens_content"
assert_contains "checks quoted APK path exists" '[ -f "$apk_path" ]' "$lens_content"
assert_contains "uses quoted APK variable for file" 'file "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for unzip inventory" 'unzip -l "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for aapt badging" 'aapt dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for aapt2 badging" 'aapt2 dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for manifest xmltree" 'aapt dump xmltree "$apk_path" AndroidManifest.xml' "$lens_content"
assert_contains "uses quoted APK variable for apksigner" 'apksigner verify --print-certs "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for apktool" 'apktool d -f -s "$apk_path" -o "$apktool_out"' "$lens_content"
assert_contains "uses quoted APK variable for jadx" 'jadx -d "$jadx_out" "$apk_path"' "$lens_content"
assert_not_contains "does not quote template APK path in commands" '"{{ANDROID_APK_PATH}}"' "$lens_content"

echo ""
echo "Test 6: decoded output uses private per-run scratch directory"
assert_contains "sets restrictive umask for scratch tree" 'umask 077' "$lens_content"
assert_contains "creates unique scratch directory" 'scratch_dir="$(mktemp -d)"' "$lens_content"
assert_contains "places apktool output under scratch tree" 'apktool_out="$scratch_dir/apktool"' "$lens_content"
assert_contains "places jadx output under scratch tree" 'jadx_out="$scratch_dir/jadx"' "$lens_content"
assert_contains "places assetlinks output under scratch tree" 'assetlinks_out="$scratch_dir/assetlinks"' "$lens_content"
assert_contains "cleans decoded scratch output" 'rm -rf -- "$scratch_dir"' "$lens_content"
assert_not_contains "does not use fixed intent-filter shared path" "/tmp/intent-filters" "$lens_content"
assert_not_contains "does not use any hard-coded tmp directory" "/tmp/" "$lens_content"

echo ""
echo "Test 7: App Link host fetching validates untrusted manifest hosts"
assert_contains "normalizes hosts before network requests" "normalize the manifest value before any network request" "$lens_content"
assert_contains "skips unsafe App Link hosts as evidence" "Skip and record as audit evidence" "$lens_content"
assert_contains "rejects wildcard hosts before fetch" "empty, \`*\`" "$lens_content"
assert_contains "rejects localhost before fetch" "\`localhost\`" "$lens_content"
assert_contains "rejects IP literal hosts before fetch" "an IP literal" "$lens_content"
assert_contains "rejects private reserved and link-local targets" "private/reserved/link-local" "$lens_content"
assert_contains "rejects bracketed IPv6 hosts" "bracketed IPv6" "$lens_content"
assert_contains "rejects malformed traversal-like host values" "malformed, traversal-like" "$lens_content"
assert_contains "rejects separators and control characters" "path separators, backslashes, control characters" "$lens_content"
assert_contains "uses validated host for assetlinks fetch" "\$validated_host/.well-known/assetlinks.json" "$lens_content"
assert_contains "uses hashed assetlinks output filename" 'assetlinks_key="$(printf' "$lens_content"
assert_contains "writes assetlinks under hashed filename" '"$assetlinks_out/${assetlinks_key}.json"' "$lens_content"
assert_contains "keeps host to filename evidence mapping" "host-to-filename note" "$lens_content"
assert_not_contains "does not fetch assetlinks with raw manifest host" '"https://$host/.well-known/assetlinks.json"' "$lens_content"
assert_not_contains "does not write assetlinks using raw host filename" '"$assetlinks_out/$host.json"' "$lens_content"

echo ""
echo "Test 8: examples avoid active device, app, and provider mutation commands"
for forbidden in \
  "adb install" \
  "pm clear" \
  "am force-stop" \
  "settings put" \
  "adb push" \
  "input tap" \
  "adb shell am start" \
  "adb shell am broadcast" \
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
