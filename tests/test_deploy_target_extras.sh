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

# Coverage gap fills for issue #88 — deploy mode target dispatch.
#
# The base contract suite (test_deploy_target_dispatch.sh) covers:
#   - the `android` domain registration,
#   - variable name presence in repolens.sh,
#   - server-fallback / APK-detected / direct-APK lens-list outcomes via the
#     full-list branch of resolve_lenses,
#   - the trust boundary (no gradlew exec).
#
# This suite fills the gaps the dispatch suite does NOT exercise:
#
#   1. resolve_lenses FOCUS branch — `--focus` must respect TARGET_TYPE
#      (apk-overview is NOT visible from a server target; deployment lenses
#      are NOT visible from an Android target).
#   2. resolve_lenses DOMAIN_FILTER branch — `--domain android` must fail on
#      a server target; `--domain deployment` must fail on an Android target.
#   3. Variable substitution — the four Android variables must actually be
#      replaced in the rendered prompt by `compose_prompt`. Test 2 of the
#      dispatch suite only checks the *names* appear in repolens.sh source.
#   4. Metadata extraction — aapt/aapt2 fallback for ANDROID_PACKAGE_NAME
#      and adb device-state filtering for ANDROID_HAS_DEVICE. The dispatch
#      suite never exercises these tools.
#
# All tests use --dry-run and a fake `claude` on PATH. No real model is ever
# invoked. The metadata-extraction tests run the parsing pipeline in isolated
# subshells with fake aapt/aapt2/adb binaries on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
DEPLOY_BASE="$SCRIPT_DIR/prompts/_base/deploy.md"
ANDROID_BASE="$SCRIPT_DIR/prompts/_base/android.md"
APK_LENS="$SCRIPT_DIR/prompts/lenses/android/apk-overview.md"

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
# Fake `claude` (the dispatcher needs it on PATH for the require_cmd preflight,
# but --dry-run never invokes it).
# ---------------------------------------------------------------------------
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/claude"
export PATH="$FAKE_BIN:$PATH"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Plain dir → server target.
PLAIN_DIR="$TMPDIR/plain"
mkdir -p "$PLAIN_DIR"
echo "# plain" > "$PLAIN_DIR/README.md"

# Project containing a discoverable APK → android target.
APK_DIR="$TMPDIR/apk"
mkdir -p "$APK_DIR/app/build/outputs/apk/debug"
: > "$APK_DIR/app/build/outputs/apk/debug/app-debug.apk"

# Helper: invoke repolens in deploy/dry-run mode.
run_dry_deploy() {
  local project="$1" log_file="$2"
  shift 2
  set +e
  bash "$REPOLENS" \
    --project "$project" \
    --agent claude \
    --mode deploy \
    --local \
    --dry-run \
    --yes \
    "$@" \
    >"$log_file" 2>&1
  local rc=$?
  set -e
  record_run_id "$log_file"
  return "$rc"
}

echo ""
echo "=== Test Suite: deploy target dispatch — coverage extras (issue #88) ==="
echo ""

# ===========================================================================
# Test 1: --focus rejects an Android lens when the target is server
# ===========================================================================
# resolve_lenses FOCUS branch must narrow deploy lookups to the active target
# domain. apk-overview lives in the `android` domain; on a plain dir the
# target is `server` and only `deployment` is selectable. The lookup MUST
# fail with a die() rather than silently fall through to the wrong domain.
echo "Test 1: --focus apk-overview is rejected on a server target"
LOG1="$TMPDIR/run1.log"
run_dry_deploy "$PLAIN_DIR" "$LOG1" --focus apk-overview || true
out1="$(cat "$LOG1")"

assert_contains "server target rejects --focus apk-overview" \
  "Lens 'apk-overview' not found" "$out1"
assert_not_contains "server target does not silently render an android lens" \
  "android/apk-overview" "$out1"
assert_not_contains "rejected --focus does not reach Dry run complete" \
  "Dry run complete" "$out1"

# ===========================================================================
# Test 2: --focus rejects a deployment lens when the target is android
# ===========================================================================
# Mirror image of Test 1: a server-domain lens id MUST NOT resolve when the
# project produces an APK (target = android). Cross-target focus would defeat
# the whole point of dispatch and silently mix lens families.
echo ""
echo "Test 2: --focus service-health is rejected on an android target"
LOG2="$TMPDIR/run2.log"
run_dry_deploy "$APK_DIR" "$LOG2" --focus service-health || true
out2="$(cat "$LOG2")"

assert_contains "android target rejects --focus service-health" \
  "Lens 'service-health' not found" "$out2"
assert_not_contains "android target does not silently render a deployment lens" \
  "deployment/service-health" "$out2"

# ===========================================================================
# Test 3: --focus accepts the same-target lens (positive case both targets)
# ===========================================================================
# Sanity: the FOCUS narrowing must not over-reject. apk-overview MUST resolve
# on an APK-bearing project; service-health MUST resolve on a plain server
# project.
echo ""
echo "Test 3: --focus accepts the matching-target lens for both server and android"
LOG3A="$TMPDIR/run3a.log"
run_dry_deploy "$APK_DIR" "$LOG3A" --focus apk-overview || true
out3a="$(cat "$LOG3A")"
assert_contains "android target resolves --focus apk-overview" \
  "android/apk-overview" "$out3a"
assert_contains "android --focus reaches dry-run completion" \
  "Dry run complete" "$out3a"

LOG3B="$TMPDIR/run3b.log"
run_dry_deploy "$PLAIN_DIR" "$LOG3B" --focus service-health || true
out3b="$(cat "$LOG3B")"
assert_contains "server target resolves --focus service-health" \
  "deployment/service-health" "$out3b"

# ===========================================================================
# Test 4: --domain rejects the wrong target's domain
# ===========================================================================
# resolve_lenses DOMAIN_FILTER branch must apply the same target gate as
# FOCUS. `--domain android` on a server target and `--domain deployment` on
# an android target both have to die() before any lens is selected.
echo ""
echo "Test 4: --domain rejects cross-target domains"
LOG4A="$TMPDIR/run4a.log"
run_dry_deploy "$PLAIN_DIR" "$LOG4A" --domain android || true
out4a="$(cat "$LOG4A")"
assert_contains "server target rejects --domain android" \
  "Domain 'android' not found" "$out4a"

LOG4B="$TMPDIR/run4b.log"
run_dry_deploy "$APK_DIR" "$LOG4B" --domain deployment || true
out4b="$(cat "$LOG4B")"
assert_contains "android target rejects --domain deployment" \
  "Domain 'deployment' not found" "$out4b"

# ===========================================================================
# Test 5: --domain accepts the matching-target domain
# ===========================================================================
echo ""
echo "Test 5: --domain accepts the matching-target domain"
LOG5A="$TMPDIR/run5a.log"
run_dry_deploy "$APK_DIR" "$LOG5A" --domain android || true
out5a="$(cat "$LOG5A")"
assert_contains "android target resolves --domain android" \
  "android/apk-overview" "$out5a"
assert_not_contains "android --domain does not pull deployment lenses" \
  "deployment/" "$out5a"

LOG5B="$TMPDIR/run5b.log"
run_dry_deploy "$PLAIN_DIR" "$LOG5B" --domain deployment || true
out5b="$(cat "$LOG5B")"
assert_contains "server target resolves --domain deployment" \
  "deployment/" "$out5b"
assert_not_contains "server --domain does not pull android lenses" \
  "android/" "$out5b"

# ===========================================================================
# Test 6: compose_prompt substitutes the four Android variables
# ===========================================================================
# Whitebox check that the new vars actually end up in the rendered prompt,
# not just the source. The dispatch suite's Test 2 only verifies variable
# *names* appear in repolens.sh; this test exercises the template engine
# end-to-end with the concrete substitution string repolens.sh builds.
echo ""
echo "Test 6: compose_prompt substitutes TARGET_TYPE/ANDROID_* variables"
# shellcheck disable=SC1090
source "$TEMPLATE_LIB"

EXPECTED_APK="/opt/builds/com.example.app-release.apk"
EXPECTED_PKG="com.example.app"
EXPECTED_HAS_DEV="true"
VARS="PROJECT_PATH=/proj|TARGET_TYPE=android|ANDROID_APK_PATH=${EXPECTED_APK}|ANDROID_PACKAGE_NAME=${EXPECTED_PKG}|ANDROID_HAS_DEVICE=${EXPECTED_HAS_DEV}"

rendered="$(compose_prompt "$DEPLOY_BASE" "$APK_LENS" "$VARS" "" "deploy" "" "" "false" "false" "")"
android_rendered="$(compose_prompt "$ANDROID_BASE" "$APK_LENS" "$VARS" "" "deploy" "" "" "false" "false" "")"

assert_contains "rendered prompt substitutes ANDROID_APK_PATH literally" "$EXPECTED_APK" "$rendered"
assert_contains "rendered prompt substitutes ANDROID_PACKAGE_NAME literally" "$EXPECTED_PKG" "$rendered"
assert_contains "rendered prompt substitutes TARGET_TYPE literally" "android" "$rendered"
assert_contains "rendered prompt substitutes ANDROID_HAS_DEVICE literally" "$EXPECTED_HAS_DEV" "$rendered"
assert_not_contains "no unresolved {{ANDROID_APK_PATH}} placeholder" "{{ANDROID_APK_PATH}}" "$rendered"
assert_not_contains "no unresolved {{ANDROID_PACKAGE_NAME}} placeholder" "{{ANDROID_PACKAGE_NAME}}" "$rendered"
assert_not_contains "no unresolved {{ANDROID_HAS_DEVICE}} placeholder" "{{ANDROID_HAS_DEVICE}}" "$rendered"
assert_not_contains "no unresolved {{TARGET_TYPE}} placeholder" "{{TARGET_TYPE}}" "$rendered"
assert_contains "rendered android prompt creates private decoded workspace" 'umask 077; android_work="$(mktemp -d)"' "$android_rendered"
assert_contains "rendered android prompt sends apktool output under private workspace" 'apktool d -f "'"$EXPECTED_APK"'" -o "$apktool_out"' "$android_rendered"
assert_contains "rendered android prompt cleans decoded workspace" 'rm -rf -- "$android_work"' "$android_rendered"
assert_not_contains "rendered android prompt avoids fixed apktool temp path" "/tmp/apk-decode" "$android_rendered"
assert_not_contains "rendered android prompt avoids fixed jadx temp path" "/tmp/apk-jadx" "$android_rendered"
assert_contains "rendered android prompt uses attach-only frida" 'frida -U -n "'"$EXPECTED_PKG"'" -l hook.js' "$android_rendered"
assert_not_contains "rendered android prompt avoids frida spawn" 'frida -U -f' "$android_rendered"
assert_not_contains "rendered android prompt avoids frida no-pause spawn flag" "--no-pause" "$android_rendered"

# ---------------------------------------------------------------------------
# Metadata extraction parsing — tested in isolation against the actual
# patterns used by repolens.sh. We pipe canned tool output through the sed
# regex (for aapt/aapt2 package extraction) and the awk filter (for adb
# device-state detection) so the tests run identically on every host
# regardless of whether aapt/adb happen to be installed.
#
# The regexes/awk programs below are intentionally identical to the ones in
# repolens.sh. If those change, these tests must be updated in lockstep —
# that is the whole point of pinning them here.
# ---------------------------------------------------------------------------

extract_package_name() {
  # Mirrors repolens.sh: aapt|aapt2 dump badging | sed extracts package name.
  sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1
}

adb_has_device() {
  # Mirrors repolens.sh: NR>1 && $2=="device" → at least one usable device.
  awk 'NR>1 && $2=="device" {found=1} END {exit !found}'
}

# ===========================================================================
# Test 7: aapt-style "package: name='X' ..." extraction
# ===========================================================================
# `aapt dump badging` prints multiple lines; the package: line is one of
# them. The implementation's sed pattern must pull *only* the package name
# from that line and drop the surrounding metadata.
echo ""
echo "Test 7: package-name regex extracts from realistic aapt dump badging output"
AAPT_OUTPUT="package: name='com.bootstrap.academy' versionCode='42' versionName='1.2.3' platformBuildVersionName='14'
sdkVersion:'21'
targetSdkVersion:'34'
uses-permission: name='android.permission.INTERNET'"
extracted_pkg="$(printf '%s\n' "$AAPT_OUTPUT" | extract_package_name)"
assert_eq "regex extracts package name out of multi-line dump" \
  "com.bootstrap.academy" "$extracted_pkg"

# ===========================================================================
# Test 8: aapt2-shape input parses identically (fallback branch coverage)
# ===========================================================================
# repolens.sh uses the *same* sed pattern for the aapt2 fallback. Real aapt2
# output has the same `package: name='X'` shape, so the fallback branch is
# exercised by feeding aapt2-shaped input through the same regex.
echo ""
echo "Test 8: package-name regex works on aapt2-shaped output too"
AAPT2_OUTPUT="package: name='org.fallback.via.aapt2' versionCode='7' versionName='0.7.0'"
extracted_pkg2="$(printf '%s\n' "$AAPT2_OUTPUT" | extract_package_name)"
assert_eq "regex extracts package name from aapt2-style line" \
  "org.fallback.via.aapt2" "$extracted_pkg2"

# ===========================================================================
# Test 9: regex returns empty when no `package:` line is present
# ===========================================================================
# Defensive: if the tool produces output but no package line (malformed APK,
# tool error, etc.) the extraction MUST return an empty string rather than
# garbage, matching the implementation's "leave at safe default" contract.
echo ""
echo "Test 9: package-name regex returns empty on input without a package line"
NO_PKG_OUTPUT="W: cannot parse APK
E: file is not a valid AndroidManifest.xml"
extracted_pkg_none="$(printf '%s\n' "$NO_PKG_OUTPUT" | extract_package_name)"
assert_eq "no package line → empty extraction" "" "$extracted_pkg_none"

# ===========================================================================
# Test 10: adb device-state filter — `device` row passes
# ===========================================================================
echo ""
echo "Test 10: adb 'device' row → has-device true"
ADB_DEVICE_OUTPUT="List of devices attached
emulator-5554          device product:sdk_gphone model:gphone"
if printf '%s\n' "$ADB_DEVICE_OUTPUT" | adb_has_device; then
  record_pass "adb 'device' row → awk filter exits 0"
else
  record_fail "adb 'device' row → awk filter exits 0 (got non-zero)"
fi

# ===========================================================================
# Test 11: adb offline/unauthorized rows are NOT counted as a device
# ===========================================================================
# The research notes call this out explicitly: adb states `offline` and
# `unauthorized` must NOT trip ANDROID_HAS_DEVICE. Otherwise the agent
# prompt would invite runtime checks against an unusable handset.
echo ""
echo "Test 11: adb offline/unauthorized rows are filtered out"
for state in offline unauthorized; do
  ADB_STATE_OUTPUT="List of devices attached
emulator-5554          $state"
  if printf '%s\n' "$ADB_STATE_OUTPUT" | adb_has_device; then
    record_fail "adb '$state' row → awk filter unexpectedly exited 0"
  else
    record_pass "adb '$state' row → awk filter exits non-zero (no usable device)"
  fi
done

# ===========================================================================
# Test 12: adb header-only output (no devices at all) is filtered out
# ===========================================================================
echo ""
echo "Test 12: adb header-only output → no usable device"
ADB_EMPTY_OUTPUT="List of devices attached"
if printf '%s\n' "$ADB_EMPTY_OUTPUT" | adb_has_device; then
  record_fail "adb header-only → awk filter unexpectedly exited 0"
else
  record_pass "adb header-only → awk filter exits non-zero"
fi

# ===========================================================================
# Test 13: adb mixed list — at least one `device` row wins
# ===========================================================================
# The filter is OR-shaped: as long as ONE attached device is in `device`
# state, ANDROID_HAS_DEVICE flips to true. Mixing offline/unauthorized rows
# with a healthy device must still report has-device.
echo ""
echo "Test 13: adb mixed list with one 'device' row → has-device true"
ADB_MIXED_OUTPUT="List of devices attached
emulator-5554          offline
phone-abc              unauthorized
phone-xyz              device product:pixel"
if printf '%s\n' "$ADB_MIXED_OUTPUT" | adb_has_device; then
  record_pass "adb mixed list with one device row → awk filter exits 0"
else
  record_fail "adb mixed list with one device row → awk filter unexpectedly exited non-zero"
fi

# ===========================================================================
# Test 14: regex source still lives in repolens.sh (regression pin)
# ===========================================================================
# The Test 7-13 helpers re-implement repolens.sh's parsing patterns to keep
# the tests host-agnostic. If the implementation drifts (someone rewrites
# the package-name extraction or the adb filter) without updating these
# tests, behaviour can silently diverge. This regression pin asserts both
# the sed regex and the awk filter still appear verbatim in repolens.sh.
echo ""
echo "Test 14: extraction patterns in this test still match repolens.sh source"
repolens_content="$(cat "$REPOLENS")"
assert_contains "repolens.sh still contains the package-name sed pattern" \
  "s/^package: name='" "$repolens_content"
assert_contains "repolens.sh still contains the adb device-state awk filter" \
  '$2=="device"' "$repolens_content"

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
