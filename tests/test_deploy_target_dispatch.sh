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

# Tests for issue #88 — deploy mode dispatch between server and Android targets.
#
# Behavioural contract:
#
#   1. domains.json defines an `android` domain with mode "deploy" and at
#      least one lens, so deploy mode can resolve Android lenses.
#
#   2. Deploy mode classifies the target before resolving lenses:
#      - Auto (default) with no APK and no Android markers     -> server target
#      - Auto with an existing APK in the project              -> android target
#      - Auto with Android source markers (build.gradle / kts) but no APK
#        -> server fallback, NEVER silently builds (trust boundary).
#      - Direct path to an .apk file via --project              -> android target
#
#   3. Domain exclusivity: a deploy run resolves only the deployment lens
#      family OR only the android lens family, never both.
#
#   4. Trust boundary: in auto mode, NO target-controlled `gradlew`,
#      `gradle`, or other build tooling is ever executed. Auto must accept
#      a discovered/direct APK or fall back to server. Source builds, if
#      retained at all, require an explicit per-run opt-in (i.e. they are
#      not implied by --yes, --auto, or `auto`).
#
#   5. Once an Android target is resolved, repolens.sh exports and
#      substitutes TARGET_TYPE, ANDROID_APK_PATH, ANDROID_PACKAGE_NAME,
#      and ANDROID_HAS_DEVICE so they reach the agent prompt.
#
# These tests drive repolens.sh through --dry-run and a fake agent CLI;
# they NEVER invoke a real model.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
REPOLENS="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPDIR="$(mktemp -d)"
CREATED_LOG_DIRS=()
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below.
_cleanup() {
  rm -rf "$TMPDIR"
  local d
  for d in "${CREATED_LOG_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

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

assert_file_absent() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (file unexpectedly exists: $path)"
  fi
}

# Parse the run_id from a repolens.sh log so we can clean up its log dir.
record_run_id() {
  local log_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null | head -1 | awk '{print $3}' || true)"
  if [[ -n "${run_id:-}" ]]; then
    CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi
}

# ---------------------------------------------------------------------------
# Fake agent + PATH override
# ---------------------------------------------------------------------------
# repolens.sh runs validate_agent + require_cmd <agent>. --dry-run never
# actually invokes the agent, but the binary must exist on PATH for the
# pre-flight check. A trivial stub satisfies that.

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
# Stub claude — never executed under --dry-run; required only for the
# require_cmd pre-flight check in repolens.sh.
exit 0
SH
chmod +x "$FAKE_BIN/claude"
export PATH="$FAKE_BIN:$PATH"

# ---------------------------------------------------------------------------
# Test fixtures (project layouts)
# ---------------------------------------------------------------------------

# Plain project dir — no APK, no Android markers.
PLAIN_DIR="$TMPDIR/plain"
mkdir -p "$PLAIN_DIR"
echo "# plain" > "$PLAIN_DIR/README.md"

# Android source project — has build.gradle but NO APK output. This is the
# canonical trust-boundary fixture: a malicious gradlew that would create a
# sentinel file if anything in repolens.sh executed it. The implementation
# under test must never run it during classification.
ANDROID_SRC_DIR="$TMPDIR/android-src"
mkdir -p "$ANDROID_SRC_DIR"
cat > "$ANDROID_SRC_DIR/build.gradle" <<'EOF'
android { compileSdkVersion 34 }
EOF
GRADLEW_SENTINEL="$TMPDIR/gradlew_was_executed.txt"
cat > "$ANDROID_SRC_DIR/gradlew" <<EOF
#!/usr/bin/env bash
# Booby-trapped fake gradlew. If repolens.sh invokes it during auto-mode
# classification, this sentinel file appears and the trust-boundary test
# below records a FAIL.
echo "MALICIOUS GRADLEW EXECUTED at \$(date -u)" > "$GRADLEW_SENTINEL"
exit 0
EOF
chmod +x "$ANDROID_SRC_DIR/gradlew"

# Android project with a discoverable APK in the standard Gradle output path.
ANDROID_APK_DIR="$TMPDIR/android-apk"
mkdir -p "$ANDROID_APK_DIR/app/build/outputs/apk/debug"
: > "$ANDROID_APK_DIR/app/build/outputs/apk/debug/app-debug.apk"

# Direct path to an .apk file (no surrounding source tree).
DIRECT_APK="$TMPDIR/standalone.apk"
: > "$DIRECT_APK"

# ---------------------------------------------------------------------------
# Helper: run repolens.sh in deploy/dry-run mode and capture stdout+stderr.
# ---------------------------------------------------------------------------
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
echo "=== Test Suite: deploy mode target dispatch (issue #88) ==="
echo ""

# ===========================================================================
# Test 1: domains.json has an `android` domain with mode "deploy" and >=1 lens
# ===========================================================================
echo "Test 1: android domain registered with mode deploy in domains.json"

android_mode="$(jq -r '.domains[] | select(.id == "android") | .mode // ""' "$DOMAINS_FILE")"
assert_eq "android domain mode is 'deploy'" "deploy" "$android_mode"

android_lens_count="$(jq -r '[.domains[] | select(.id == "android") | .lenses[]] | length' "$DOMAINS_FILE" 2>/dev/null || echo 0)"
TOTAL=$((TOTAL + 1))
if [[ "$android_lens_count" =~ ^[0-9]+$ ]] && (( android_lens_count >= 1 )); then
  PASS=$((PASS + 1))
  echo "  PASS: android domain registers at least one lens (count=$android_lens_count)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: android domain must register at least one lens (count=$android_lens_count)"
fi

# Sanity: every registered android lens has a prompt file. The dispatch
# only works end-to-end if these files exist; without them repolens.sh
# dies with "Missing lens prompt".
TOTAL=$((TOTAL + 1))
missing_prompts=""
while IFS= read -r lens_id; do
  [[ -z "$lens_id" ]] && continue
  if [[ ! -f "$SCRIPT_DIR/prompts/lenses/android/$lens_id.md" ]]; then
    missing_prompts+=" $lens_id"
  fi
done < <(jq -r '.domains[] | select(.id == "android") | .lenses[]?' "$DOMAINS_FILE" 2>/dev/null)
if [[ -z "$missing_prompts" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: every android lens id has a corresponding prompt file"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: android lens prompt files missing for:$missing_prompts"
fi

# ===========================================================================
# Test 2: repolens.sh threads the four Android prompt variables
# ===========================================================================
# White-box but minimal: the issue contract says TARGET_TYPE,
# ANDROID_APK_PATH, ANDROID_PACKAGE_NAME, and ANDROID_HAS_DEVICE must be
# exported and reach the template engine. Verifying each name appears
# somewhere in repolens.sh proves the implementer wired all four; absence
# would mean the agent prompt could not substitute them.
echo ""
echo "Test 2: repolens.sh references all four Android target variables"
repolens_src="$(cat "$REPOLENS")"
for var in TARGET_TYPE ANDROID_APK_PATH ANDROID_PACKAGE_NAME ANDROID_HAS_DEVICE; do
  TOTAL=$((TOTAL + 1))
  if [[ "$repolens_src" == *"$var"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $var referenced in repolens.sh"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $var not referenced in repolens.sh"
  fi
done

# ===========================================================================
# Test 3: deploy on a plain dir resolves ONLY deployment/* lenses (server fallback)
# ===========================================================================
echo ""
echo "Test 3: deploy mode on a plain directory falls back to server target"
LOG3="$TMPDIR/run3.log"
run_dry_deploy "$PLAIN_DIR" "$LOG3" || true
out3="$(cat "$LOG3")"

assert_contains "plain dir resolves at least one deployment/* lens" "deployment/" "$out3"
assert_not_contains "plain dir does NOT resolve any android/* lens" "android/" "$out3"
assert_contains "plain dir reaches the dry-run output marker" "Dry run complete" "$out3"

# ===========================================================================
# Test 4: deploy on a project with an existing APK → android target (auto)
# ===========================================================================
echo ""
echo "Test 4: deploy mode on a project with an existing APK selects android target"
LOG4="$TMPDIR/run4.log"
run_dry_deploy "$ANDROID_APK_DIR" "$LOG4" || true
out4="$(cat "$LOG4")"

assert_contains "APK-bearing project resolves at least one android/* lens" "android/" "$out4"
assert_not_contains "APK-bearing project does NOT resolve any deployment/* lens" "deployment/" "$out4"
assert_contains "APK-bearing project reaches the dry-run output marker" "Dry run complete" "$out4"

# ===========================================================================
# Test 5 (TRUST BOUNDARY): a Gradle source tree with a booby-trapped gradlew
# must never have that gradlew executed during classification.
# ===========================================================================
# This is the central safety property from issue #189: auto-classification
# of an Android-source-looking tree must not execute project-controlled
# build tooling directly. repolens.sh may call a `build_android_apk` helper
# (#187) when one is present, but the helper — not repolens.sh — owns the
# authorization / confirm / dry-run gating. The load-bearing invariant here
# is that the malicious gradlew sentinel never appears.
#
# Target-type is intentionally not asserted: today (no build_android_apk
# helper merged yet) classification falls back to server; once #187 lands,
# the same source tree will legitimately resolve to android. Either outcome
# is acceptable as long as the sentinel stays absent.
echo ""
echo "Test 5 (TRUST BOUNDARY): auto mode must not execute project-controlled gradlew"
LOG5="$TMPDIR/run5.log"
rm -f "$GRADLEW_SENTINEL"
run_dry_deploy "$ANDROID_SRC_DIR" "$LOG5" || true
out5="$(cat "$LOG5")"

assert_file_absent "trust boundary: gradlew was NOT executed during classification" "$GRADLEW_SENTINEL"
assert_contains "trust boundary: dry-run completes cleanly" "Dry run complete" "$out5"

# ===========================================================================
# Test 6: a direct .apk file path as --project is accepted as Android target
# ===========================================================================
# Today repolens.sh dies with "Cannot access project path: ..." when --project
# points at a file (because it cd's into PROJECT_PATH). #88 says an APK target
# must be supportable. Direct-APK acceptance + android lens resolution proves
# the implementer routed file inputs into the Android target classifier
# rather than rejecting them at directory-normalization time.
echo ""
echo "Test 6: direct .apk path as --project is accepted and dispatches to android"
LOG6="$TMPDIR/run6.log"
run_dry_deploy "$DIRECT_APK" "$LOG6" || true
out6="$(cat "$LOG6")"

assert_not_contains "direct APK path is not rejected as a missing project" "Cannot access project path" "$out6"
assert_not_contains "direct APK path is not rejected as a non-git repo" "Not a git repository" "$out6"
assert_contains "direct APK path resolves android/* lenses" "android/" "$out6"
assert_not_contains "direct APK path does NOT resolve deployment/* lenses" "deployment/" "$out6"

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
