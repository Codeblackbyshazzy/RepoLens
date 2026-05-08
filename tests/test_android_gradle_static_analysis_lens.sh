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

# Tests for issue #107 - Android Gradle source static analysis lens.
#
# Behavioural contract:
#   - android/gradle-static-analysis exists and is registered in config/domains.json.
#   - The prompt covers Android Lint, detekt, ktlint, Spotless, SDK, manifest
#     merger, R8/ProGuard, suppression, and baseline concerns named in the issue.
#   - Shell examples use the exported runtime project path through a local shell
#     variable, not quoted template paths.
#   - Examples avoid unrelated Android device and app mutation commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/gradle-static-analysis.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
CORE_FILE="$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d "$SCRIPT_DIR/.tmp-android-gradle-static.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

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
echo "=== Test Suite: Android Gradle source static analysis lens (issue #107) ==="
echo ""

echo "Test 1: lens file exists"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "gradle-static-analysis lens file exists"
else
  record_fail "gradle-static-analysis lens file exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: gradle-static-analysis" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: Android Source Static Analysis Auditor" "$lens_content"
assert_contains "role frontmatter" "role: Android Source Tree Static Analysis Specialist" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses[]' "$DOMAINS_FILE")"
assert_contains "registered android lens list includes gradle-static-analysis" "gradle-static-analysis" "$android_lenses"

echo ""
echo "Test 4: Android Lint rules and deprecated API concerns are covered"
for term in \
  "HardcodedDebugMode" \
  "AllowBackup" \
  "ExportedActivity" \
  "ExportedReceiver" \
  "ExportedService" \
  "AddJavascriptInterface" \
  "SetJavaScriptEnabled" \
  "MissingPermission" \
  "JavascriptInterface" \
  "TrustAllX509TrustManager" \
  "BadHostnameVerifier" \
  "AsyncTask" \
  "FragmentManager"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 5: Gradle static analysis tools and posture checks are covered"
for term in \
  "detekt" \
  "PotentiallyDangerousApi" \
  "ComplexMethod" \
  "LongMethod" \
  "TooManyFunctions" \
  "ktlintCheck" \
  "spotlessCheck" \
  "dependencyUpdates" \
  "minSdk" \
  "targetSdk" \
  "compileSdk" \
  "AndroidManifest.xml" \
  "manifest merger" \
  "R8/ProGuard" \
  "minifyEnabled" \
  "proguard-rules.pro" \
  "proguard-android-optimize.txt"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 6: suppressions and baselines are covered"
for term in \
  "lint-baseline.xml" \
  "tools:ignore" \
  "@Suppress" \
  "@SuppressLint" \
  "baseline"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: source-tree gating and shell-safe project variable are present"
assert_contains "requires build.gradle" "build.gradle" "$lens_content"
assert_contains "requires build.gradle.kts" "build.gradle.kts" "$lens_content"
assert_contains "requires Gradle wrapper" "gradlew" "$lens_content"
assert_contains "has skipped finding text" "gradle-static-analysis lens skipped" "$lens_content"
assert_contains "assigns runtime project path to local variable" 'project_path=${PROJECT_PATH:?PROJECT_PATH is required}' "$lens_content"
assert_contains "checks quoted project path is a directory" '[ -d "$project_path" ]' "$lens_content"
assert_contains "cd uses quoted project path variable" 'cd "$project_path" || exit' "$lens_content"
assert_contains "runs wrapper version check" "./gradlew --version" "$lens_content"
assert_contains "runs Android Lint" "./gradlew lint" "$lens_content"
assert_not_contains "does not quote template project path in commands" '"{{PROJECT_PATH}}"' "$lens_content"

echo ""
echo "Test 8: run_agent exports PROJECT_PATH to agent subprocesses"
PROJECT_FIXTURE="$TMPDIR/project with spaces"
FAKE_BIN="$TMPDIR/bin"
ENV_CAPTURE="$TMPDIR/project-path.txt"
PWD_CAPTURE="$TMPDIR/pwd.txt"
mkdir -p "$PROJECT_FIXTURE" "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${PROJECT_PATH:-}" > "${REPOLENS_ENV_CAPTURE:?}"
printf '%s\n' "$PWD" > "${REPOLENS_PWD_CAPTURE:?}"
echo "DONE"
SH
chmod +x "$FAKE_BIN/codex"

(
  export PATH="$FAKE_BIN:$PATH"
  export REPOLENS_ENV_CAPTURE="$ENV_CAPTURE"
  export REPOLENS_PWD_CAPTURE="$PWD_CAPTURE"
  export REPOLENS_AGENT_TIMEOUT=5
  export REPOLENS_AGENT_KILL_GRACE=2
  # shellcheck disable=SC1090
  source "$CORE_FILE"
  run_agent codex "test prompt" "$PROJECT_FIXTURE" "$REPOLENS_AGENT_TIMEOUT" "$REPOLENS_AGENT_KILL_GRACE" >/dev/null 2>&1
)
run_agent_rc=$?

if [[ $run_agent_rc -eq 0 ]]; then
  record_pass "run_agent executes fake codex successfully"
else
  record_fail "run_agent executes fake codex successfully (exit $run_agent_rc)"
fi

captured_project_path=""
captured_pwd=""
[[ -f "$ENV_CAPTURE" ]] && captured_project_path="$(cat "$ENV_CAPTURE")"
[[ -f "$PWD_CAPTURE" ]] && captured_pwd="$(cat "$PWD_CAPTURE")"

if [[ "$captured_project_path" == "$PROJECT_FIXTURE" ]]; then
  record_pass "agent receives exported PROJECT_PATH"
else
  record_fail "agent receives exported PROJECT_PATH (got '$captured_project_path')"
fi

if [[ "$captured_pwd" == "$PROJECT_FIXTURE" ]]; then
  record_pass "agent still runs inside project directory"
else
  record_fail "agent still runs inside project directory (got '$captured_pwd')"
fi

echo ""
echo "Test 9: examples avoid mutation commands and fixed shared output paths"
for forbidden in \
  "adb install" \
  "pm clear" \
  "am force-stop" \
  "settings put" \
  "adb push" \
  "input tap" \
  "ktlintFormat" \
  "spotlessApply" \
  "/tmp/"; do
  assert_not_contains "does not mention $forbidden" "$forbidden" "$lens_content"
done

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
