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

# Behavioral tests for issue #122: status is a pure reader and must not enter
# normal audit dependency checks for agent CLIs or forge tooling.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/status_test_lib.sh
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    record_fail "$desc" "unexpected needle='$needle'"
  else
    record_pass "$desc"
  fi
}

echo "=== status command does not require normal run dependencies ==="
status_require_jq

RUN_ID="status-no-deps-test"
RUN_DIR="$STATUS_TEST_ROOT/logs/$RUN_ID"
FAKE_BIN="$STATUS_TEST_TMPDIR/bin"
OUT_FILE="$STATUS_TEST_TMPDIR/status.out"
ERR_FILE="$STATUS_TEST_TMPDIR/status.err"
mkdir -p "$RUN_DIR" "$FAKE_BIN"
status_register_run_id "$RUN_ID"
jq --arg run "$RUN_ID" '.run_id = $run' \
  "$STATUS_TEST_ROOT/tests/fixtures/status_active.json" > "$RUN_DIR/status.json"

for cmd in gh git claude codex opencode timeout; do
  cat > "$FAKE_BIN/$cmd" <<'SH'
#!/usr/bin/env bash
echo "masked dependency should not be invoked: ${0##*/}" >&2
exit 97
SH
  chmod +x "$FAKE_BIN/$cmd"
done

PATH="$FAKE_BIN:$PATH" bash "$STATUS_TEST_ROOT/repolens.sh" status "$RUN_ID" --no-color >"$OUT_FILE" 2>"$ERR_FILE"
rc=$?
combined="$(cat "$OUT_FILE")$(cat "$ERR_FILE")"

assert_eq "Status render succeeds with normal dependencies masked" "0" "$rc"
assert_contains "Dependency-masked status still renders run" "RepoLens run status-no-deps-test" "$combined"
assert_not_contains "Status command does not invoke masked dependencies" "masked dependency should not be invoked" "$combined"

status_finish
