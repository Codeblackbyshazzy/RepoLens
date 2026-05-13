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

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
DEPLOY_BASE="$SCRIPT_DIR/prompts/_base/deploy.md"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/deployment/service-health.md"

# shellcheck source=../lib/template.sh
source "$TEMPLATE_LIB"

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
    record_fail "$desc (expected to contain '$needle')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (unexpected '$needle' present)"
  fi
}

base_vars="PROJECT_PATH=/tmp/project|DOMAIN=deployment|DOMAIN_NAME=Deployment|DOMAIN_COLOR=ededed|LENS_ID=service-health|LENS_NAME=Service Health|LENS_LABEL=deploy:deployment/service-health|MODE=deploy|RUN_ID=test|REPO_NAME=repo|REPO_OWNER=owner|FORGE_REPO_SLUG=owner/repo|FORGE_ISSUE_CREATE=gh issue create --repo owner/repo|FORGE_LABEL_CREATE=gh label create deploy:deployment/service-health --repo owner/repo|FORGE_ISSUE_LIST_OPEN=gh issue list --repo owner/repo --state open|TARGET_TYPE=server|REPOLENS_DEPLOY_TARGET_KIND=server|ANDROID_APK_PATH=|ANDROID_PACKAGE_NAME=|ANDROID_HAS_DEVICE=|REPOLENS_ANDROID_APK_PATH="

echo ""
echo "=== Test Suite: remote-aware deploy prompt (issue #198) ==="
echo ""

echo "Test 1: local deploy render omits remote-only instructions"
local_rendered="$(compose_prompt "$DEPLOY_BASE" "$LENS_FILE" "$base_vars" "" "deploy" "" "" "false" "false" "")"

assert_not_contains "local render omits remote execution title" \
  "REMOTE EXECUTION -- Wrap Every Command in SSH" "$local_rendered"
assert_not_contains "local render clears remote placeholder" \
  "{{REMOTE_EXECUTION_SECTION}}" "$local_rendered"
assert_not_contains "local render clears server investigation placeholder" \
  "{{SERVER_INVESTIGATION_SECTION}}" "$local_rendered"
assert_contains "local render keeps local server examples" \
  '`uname -a`, `uptime`, `hostnamectl`' "$local_rendered"

echo ""
echo "Test 2: remote deploy render includes SSH wrapper instructions"
remote_vars="${base_vars}|REPOLENS_REMOTE_TARGET=ubuntu@host.example.com:2222|REPOLENS_REMOTE_LABEL=Server C (rss.the-morpheus.news)"
remote_rendered="$(compose_prompt "$DEPLOY_BASE" "$LENS_FILE" "$remote_vars" "" "deploy" "" "" "false" "false" "")"

assert_contains "remote render includes remote execution title" \
  "## REMOTE EXECUTION -- Wrap Every Command in SSH" "$remote_rendered"
assert_contains "remote render includes exact command template" \
  "ssh -S \"\$REPOLENS_REMOTE_SSH_SOCKET\" \"\$REPOLENS_REMOTE_TARGET\" 'CMD'" "$remote_rendered"
assert_contains "remote render includes simple worked example" \
  "ssh -S \"\$REPOLENS_REMOTE_SSH_SOCKET\" \"\$REPOLENS_REMOTE_TARGET\" 'uname -a'" "$remote_rendered"
assert_contains "remote render includes piped worked example intact" \
  "ssh -S \"\$REPOLENS_REMOTE_SSH_SOCKET\" \"\$REPOLENS_REMOTE_TARGET\" 'journalctl -u customrss-api --no-pager -n 50 | grep ERROR'" "$remote_rendered"
assert_contains "remote render includes wrong-machine warning" \
  "Do NOT run any system command without the ssh wrapper. The local machine where you are running is the operator's workstation, NOT the production target. Local commands will return data about the wrong machine." "$remote_rendered"
assert_contains "remote render includes labelled hostname check" \
  "confirm the hostname matches \`Server C (rss.the-morpheus.news)\`" "$remote_rendered"
assert_contains "remote render keeps forge commands local" \
  "Do NOT wrap issue creation, issue listing, label creation, or other forge CLI commands in SSH" "$remote_rendered"

echo ""
echo "Test 3: remote investigation examples are pre-wrapped"
assert_contains "remote render wraps system overview command" \
  "ssh -S \"\$REPOLENS_REMOTE_SSH_SOCKET\" \"\$REPOLENS_REMOTE_TARGET\" 'uname -a'" "$remote_rendered"
assert_contains "remote render wraps service command" \
  "ssh -S \"\$REPOLENS_REMOTE_SSH_SOCKET\" \"\$REPOLENS_REMOTE_TARGET\" 'systemctl list-units --type=service --state=running'" "$remote_rendered"
assert_contains "remote render wraps network command" \
  "ssh -S \"\$REPOLENS_REMOTE_SSH_SOCKET\" \"\$REPOLENS_REMOTE_TARGET\" 'ss -tlnp'" "$remote_rendered"
assert_contains "remote render wraps disk command" \
  "ssh -S \"\$REPOLENS_REMOTE_SSH_SOCKET\" \"\$REPOLENS_REMOTE_TARGET\" 'df -h'" "$remote_rendered"
assert_not_contains "remote render removes local server command list" \
  '`uname -a`, `uptime`, `hostnamectl`' "$remote_rendered"
assert_not_contains "remote render has no unresolved remote placeholder" \
  "{{REPOLENS_REMOTE_LABEL}}" "$remote_rendered"
assert_not_contains "remote render has no unresolved section placeholder" \
  "{{REMOTE_EXECUTION_SECTION}}" "$remote_rendered"

echo ""
echo "Test 4: escaped remote label pipes cannot override remote target"
injection_vars="${base_vars}|REPOLENS_REMOTE_TARGET=ubuntu@host.example.com:2222|REPOLENS_REMOTE_LABEL=Prod\\|REPOLENS_REMOTE_TARGET="
injection_rendered="$(compose_prompt "$DEPLOY_BASE" "$LENS_FILE" "$injection_vars" "" "deploy" "" "" "false" "false" "")"

assert_contains "escaped pipe label still renders remote execution title" \
  "## REMOTE EXECUTION -- Wrap Every Command in SSH" "$injection_rendered"
assert_contains "escaped pipe label preserves literal label text" \
  "confirm the hostname matches \`Prod|REPOLENS_REMOTE_TARGET=\`" "$injection_rendered"
assert_contains "escaped pipe label still renders SSH-wrapped investigation examples" \
  "ssh -S \"\$REPOLENS_REMOTE_SSH_SOCKET\" \"\$REPOLENS_REMOTE_TARGET\" 'systemctl list-units --type=service --state=running'" "$injection_rendered"
assert_not_contains "escaped pipe label does not fall back to local server examples" \
  '`uname -a`, `uptime`, `hostnamectl`' "$injection_rendered"

echo ""
echo "=== Results ==="
echo "Total: $TOTAL"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

exit 0
