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

# Tests for issue #101 - Android TLS pinning and MITM lens.
#
# Behavioural contract:
#   - android/ssl-pinning-mitm exists and is registered in config/domains.json.
#   - The prompt covers pinning bypass, coverage gaps, plaintext flow,
#     request-signing, replay, and backend API risks named in the issue.
#   - Dynamic work is gated on ANDROID_HAS_DEVICE and remains read-only.
#   - Host-side decoded and loopback-bound MITM output uses a private scratch
#     directory.
#   - Examples avoid device/app/trust mutation commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/ssl-pinning-mitm.md"
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
echo "=== Test Suite: Android TLS pinning and MITM lens (issue #101) ==="
echo ""

echo "Test 1: lens file exists"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "ssl-pinning-mitm lens file exists"
else
  record_fail "ssl-pinning-mitm lens file exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: ssl-pinning-mitm" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: TLS Pinning Bypass & MITM Auditor" "$lens_content"
assert_contains "role frontmatter" "role: Mobile TLS Pinning Specialist" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses[]' "$DOMAINS_FILE")"
assert_contains "registered android lens list includes ssl-pinning-mitm" "ssl-pinning-mitm" "$android_lenses"

echo ""
echo "Test 4: issue pinning, MITM, and backend risks are covered"
for term in \
  "CertificatePinner" \
  "Network Security Config" \
  "pin-set" \
  "HostnameVerifier" \
  "X509TrustManager" \
  "frida" \
  "objection" \
  "mitmproxy" \
  "GraphQL introspection" \
  "Authorization" \
  "Bearer" \
  "PII" \
  "HMAC" \
  "nonce" \
  "timestamp" \
  "replay" \
  "analytics" \
  "crash" \
  "ads"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 5: commands use safe Android variables"
assert_contains "assigns runtime APK path to local variable" 'apk_path=${ANDROID_APK_PATH:?ANDROID_APK_PATH is required}' "$lens_content"
assert_contains "checks quoted APK path exists" '[ -f "$apk_path" ]' "$lens_content"
assert_contains "assigns package name to local variable" 'package_name=${ANDROID_PACKAGE_NAME:-unknown}' "$lens_content"
assert_contains "gates dynamic work on Android device availability" '{{ANDROID_HAS_DEVICE}}' "$lens_content"
assert_contains "uses quoted APK variable for badging" 'aapt dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for aapt xmltree" 'aapt dump xmltree "$apk_path" AndroidManifest.xml' "$lens_content"
assert_contains "uses quoted APK variable for unzip inventory" 'unzip -l "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for DEX streaming" 'unzip -p "$apk_path" classes.dex | strings' "$lens_content"
assert_contains "uses quoted APK variable for apktool" 'apktool d -f "$apk_path" -o "$apktool_out"' "$lens_content"
assert_contains "uses quoted APK variable for jadx" 'jadx -d "$jadx_out" "$apk_path"' "$lens_content"
assert_not_contains "does not quote template APK path in commands" '"{{ANDROID_APK_PATH}}"' "$lens_content"

echo ""
echo "Test 6: decoded and MITM output uses private scratch directory"
assert_contains "sets restrictive umask for scratch tree" 'umask 077' "$lens_content"
assert_contains "creates unique scratch directory" 'scratch_dir="$(mktemp -d)"' "$lens_content"
assert_contains "places apktool output under scratch tree" 'apktool_out="$scratch_dir/apktool"' "$lens_content"
assert_contains "places jadx output under scratch tree" 'jadx_out="$scratch_dir/jadx"' "$lens_content"
assert_contains "places mitm flow under scratch tree" 'flow_file="$scratch_dir/mitm.flow"' "$lens_content"
assert_contains "cleans scratch output" 'rm -rf -- "$scratch_dir"' "$lens_content"
assert_not_contains "does not use fixed shared mitm path" "/tmp/mitm" "$lens_content"
assert_not_contains "does not use any hard-coded tmp directory" "/tmp/" "$lens_content"

echo ""
echo "Test 7: MITM capture examples bind to loopback"
assert_contains "mitmproxy binds to loopback with explicit listen port" 'mitmproxy --mode regular --listen-host 127.0.0.1 --listen-port 8080 -w "$flow_file"' "$lens_content"
assert_contains "mitmdump binds to loopback with explicit listen port" 'mitmdump --mode regular --listen-host 127.0.0.1 --listen-port 8080 -w "$flow_file"' "$lens_content"
assert_not_contains "does not leave mitmproxy implicit port binding" 'mitmproxy --mode regular -p 8080' "$lens_content"
assert_not_contains "does not leave mitmdump implicit port binding" 'mitmdump --mode regular -p 8080' "$lens_content"

echo ""
echo "Test 8: examples avoid active device, app, and trust mutation commands"
for forbidden in \
  "adb logcat -c" \
  "adb shell am start" \
  "adb install" \
  "adb push" \
  "adb root" \
  "pm clear" \
  "am force-stop" \
  "settings put" \
  "input tap" \
  "frida -U -f" \
  "Interceptor.replace"; do
  assert_not_contains "does not mention $forbidden" "$forbidden" "$lens_content"
done

echo ""
echo "Test 9: reporting requires sensitive value redaction"
for sensitive in \
  "tokens" \
  "cookies" \
  "PII" \
  "PCI" \
  "request/response body secrets"; do
  assert_contains "requires redaction for $sensitive" "$sensitive" "$lens_content"
done
assert_contains "requires redaction of full values" "Redact full tokens" "$lens_content"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
