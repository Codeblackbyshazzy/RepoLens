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

# Integration tests for issue #213. Persistent auth/model/budget failures from
# the agent should abort the whole run after one failed iteration and surface
# the exact class in summary.json.stopped_reason.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
CREATED_RUNS=()
trap 'rm -rf "$TMPDIR"; for run_id in "${CREATED_RUNS[@]:-}"; do rm -rf "$SCRIPT_DIR/logs/$run_id"; done' EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_ge() {
  local desc="$1" floor="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" =~ ^[0-9]+$ && "$actual" -ge "$floor" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected >= $floor, got '$actual'"
  fi
}

assert_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit status"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing '$needle'"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    fail_with "$desc" "Unexpected '$needle'"
  else
    pass_with "$desc"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing file $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpected file $path"
  fi
}

assert_zero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected zero exit status, got $actual"
  fi
}

create_project() {
  local project="$1"
  mkdir -p "$project"
  (
    cd "$project" || exit 1
    git init -q 2>/dev/null
    git config user.email test@example.com
    git config user.name Test
    printf '# fixture\n' > README.md
    git add README.md
    git commit -q -m init 2>/dev/null
  ) || true
}

install_persistent_failure_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

state_dir="${FAKE_AGENT_STATE_DIR:?}"
mkdir -p "$state_dir"
counter_file="$state_dir/calls"
count=0
if [[ -f "$counter_file" ]]; then
  count="$(cat "$counter_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"

case "${FAKE_AGENT_FAILURE_CLASS:?}" in
  auth-expired)
    printf 'Not logged in · Please run /login\n'
    ;;
  model-unavailable)
    printf "There's an issue with the selected model (claude-missing). It may not exist or may not be available to your account.\n"
    ;;
  budget-exhausted)
    printf 'Error: Exceeded USD budget (0.0001)\n'
    ;;
  *)
    printf 'unknown fake class: %s\n' "${FAKE_AGENT_FAILURE_CLASS:?}" >&2
    exit 2
    ;;
esac
exit 1
SH
  chmod +x "$bin_dir/codex"
}

install_success_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

state_dir="${FAKE_AGENT_STATE_DIR:?}"
mkdir -p "$state_dir"
counter_file="$state_dir/calls"
count=0
if [[ -f "$counter_file" ]]; then
  count="$(cat "$counter_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"

printf 'Persistent failure has been resolved.\nDONE\n'
exit 0
SH
  chmod +x "$bin_dir/codex"
}

extract_run_id() {
  local output_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$output_file" | head -1 | awk '{print $3}'
}

run_case() {
  local class="$1"
  local case_dir="$TMPDIR/$class"
  local project="$case_dir/project"
  local bin_dir="$case_dir/bin"
  local output_file="$case_dir/run.log"
  local run_id summary_file rc stopped_reason status_count skipped_count iter_count completed_count call_count

  mkdir -p "$case_dir"
  create_project "$project"
  install_persistent_failure_codex "$bin_dir"

  set +e
  FAKE_AGENT_FAILURE_CLASS="$class" \
  FAKE_AGENT_STATE_DIR="$case_dir/state" \
  PATH="$bin_dir:$PATH" \
  REPOLENS_NO_PROGRESS_LIMIT=3 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$project" \
    --agent codex \
    --domain i18n \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    >"$output_file" 2>&1
  rc=$?
  set -e

  run_id="$(extract_run_id "$output_file")"
  if [[ -n "$run_id" ]]; then
    CREATED_RUNS+=("$run_id")
  fi
  summary_file="$SCRIPT_DIR/logs/$run_id/summary.json"

  echo "--- $class ---"
  assert_nonzero "$class run exits non-zero" "$rc"
  assert_file_exists "$class run writes summary.json" "$summary_file"
  assert_file_exists "$class run writes systemic abort sentinel" "$SCRIPT_DIR/logs/$run_id/.systemic-failure-abort"
  assert_eq "$class sentinel stores exact class" "$class" "$(head -n 1 "$SCRIPT_DIR/logs/$run_id/.systemic-failure-abort" 2>/dev/null || printf missing)"
  assert_contains "$class log mentions class" "$class" "$output_file"
  assert_not_contains "$class does not fall through to no-progress breaker" "No-progress circuit breaker tripped" "$output_file"
  assert_not_contains "$class does not hit safety cap" "Hit safety cap" "$output_file"
  assert_not_contains "$class does not run a second iteration" "Iteration 2" "$output_file"

  stopped_reason="$(jq -r '.stopped_reason' "$summary_file" 2>/dev/null || printf missing)"
  assert_eq "$class stopped_reason is distinct" "$class" "$stopped_reason"

  status_count="$(jq --arg class "$class" '[.lenses[] | select(.status == $class)] | length' "$summary_file" 2>/dev/null || printf 0)"
  assert_eq "$class records one failed lens with class status" "1" "$status_count"

  iter_count="$(jq --arg class "$class" '[.lenses[] | select(.status == $class) | .iterations] | .[0]' "$summary_file" 2>/dev/null || printf missing)"
  assert_eq "$class failed lens stops after one iteration" "1" "$iter_count"

  skipped_count="$(jq '[.lenses[] | select(.status == "skipped")] | length' "$summary_file" 2>/dev/null || printf 0)"
  assert_ge "$class records unstarted lenses as skipped" "1" "$skipped_count"

  call_count="$(cat "$case_dir/state/calls" 2>/dev/null || printf 0)"
  assert_eq "$class invokes fake agent once" "1" "$call_count"

  completed_count=0
  if [[ -f "$SCRIPT_DIR/logs/$run_id/.completed" ]]; then
    while IFS= read -r lens_entry; do
      if grep -qxF "$lens_entry" "$SCRIPT_DIR/logs/$run_id/.completed" 2>/dev/null; then
        completed_count=$((completed_count + 1))
      fi
    done < <(jq --arg class "$class" -r '.lenses[] | select(.status == $class) | "\(.domain)/\(.lens)"' "$summary_file" 2>/dev/null)
  fi
  assert_eq "$class failed lens is not marked completed" "0" "$completed_count"
}

run_resume_cleanup_case() {
  local run_id="test-systemic-resume-$RANDOM"
  local resume_dir="$SCRIPT_DIR/logs/$run_id"
  local case_dir="$TMPDIR/resume-cleanup"
  local output_file="$case_dir/run.log"
  local rc

  CREATED_RUNS+=("$run_id")
  mkdir -p "$resume_dir/rounds/round-1" "$resume_dir/output/i18n/i18n-strings" "$case_dir"
  create_project "$case_dir/project"
  install_success_codex "$case_dir/bin"

  printf 'i18n/i18n-formatting\n' > "$resume_dir/.completed"
  printf '%s\n' "auth-expired" > "$resume_dir/.systemic-failure-abort"
  printf '{"run_id":"%s","rounds_total":1,"total_lenses":2,"lens_list":["i18n/i18n-strings","i18n/i18n-formatting"]}\n' "$run_id" > "$resume_dir/rounds/round-1/metadata.json"
  printf '{"run_id":"%s","project_path":"","mode":"audit","agent":"codex","started_at":"2026-05-14T00:00:00Z","completed_at":null,"stopped_reason":"auth-expired","lenses":[{"domain":"i18n","lens":"i18n-strings","iterations":1,"status":"auth-expired","issues_created":0,"rate_limit_sleep_seconds":0}],"totals":{"lenses_run":1,"iterations_total":1,"issues_created":0}}\n' "$run_id" > "$resume_dir/summary.json"

  set +e
  FAKE_AGENT_STATE_DIR="$case_dir/state" \
  PATH="$case_dir/bin:$PATH" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$case_dir/project" \
    --agent codex \
    --domain i18n \
    --mode audit \
    --depth 1 \
    --local \
    --yes \
    --resume "$run_id" \
    >"$output_file" 2>&1
  rc=$?
  set -e

  echo "--- resume cleanup ---"
  assert_zero "resume after systemic failure succeeds" "$rc"
  assert_file_missing "resume removes stale systemic abort sentinel" "$resume_dir/.systemic-failure-abort"
  assert_eq "resume clears stale stopped_reason" "null" "$(jq -r '.stopped_reason' "$resume_dir/summary.json" 2>/dev/null || printf missing)"
  assert_contains "resume marks retried lens completed" "i18n/i18n-strings" "$resume_dir/.completed"
  assert_eq "resume appends completed retry result" "1" "$(jq '[.lenses[] | select(.domain == "i18n" and .lens == "i18n-strings" and .status == "completed")] | length' "$resume_dir/summary.json" 2>/dev/null || printf 0)"
  assert_eq "resume invokes fake agent once" "1" "$(cat "$case_dir/state/calls" 2>/dev/null || printf 0)"
}

echo "=== persistent agent failure abort (issue #213) ==="

run_case "auth-expired"
run_case "model-unavailable"
run_case "budget-exhausted"
run_resume_cleanup_case

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
