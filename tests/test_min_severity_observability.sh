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

# Issue #262: min-severity filtering of synthesizer manifest findings must be
# observable in the run log and summary.json.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNTHESIZE_LIB="$SCRIPT_DIR/lib/synthesize.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"
SUMMARY_LIB="$SCRIPT_DIR/lib/summary.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0

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

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
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

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_file_matches() {
  local desc="$1" path="$2" regex="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]] && grep -Eq "$regex" "$path"; then
    pass_with "$desc"
  else
    local detail="Missing regex '$regex'"
    if [[ -f "$path" ]]; then
      detail+=" in $(cat "$path")"
    else
      detail+=" because $path does not exist"
    fi
    fail_with "$desc" "$detail"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

if [[ ! -f "$SYNTHESIZE_LIB" ]]; then
  echo "  FAIL: lib/synthesize.sh missing at $SYNTHESIZE_LIB"
  exit 1
fi

# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$LOGGING_LIB"
# shellcheck disable=SC1090
source "$SUMMARY_LIB"
# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$SYNTHESIZE_LIB"

TMP_PARENT="$SCRIPT_DIR/tests/logs/test-min-severity-observability"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
  rmdir "$SCRIPT_DIR/tests/logs" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== synthesizer manifest min-severity observability ==="

run_id="run-min-severity-observability"
RUN_LOG="$TMPDIR/$run_id"
PROJECT_PATH="$TMPDIR/project"
SUMMARY_FILE="$RUN_LOG/summary.json"
COMPOSE_LOG="$TMPDIR/compose.log"
AGENT_LOG="$TMPDIR/agent.log"

mkdir -p "$PROJECT_PATH"
mkdir -p "$RUN_LOG/rounds/round-1/lens-outputs/security"
printf 'raw finding fixture\n' > "$RUN_LOG/rounds/round-1/lens-outputs/security/injection.md"

export AGENT=codex
export PROJECT_PATH
export LOG_BASE="$RUN_LOG"
export SUMMARY_FILE
export MODE=bugreport
export REPOLENS_MODE=bugreport
# repolens.sh normalizes --min-severity high into this exported value before
# invoking the synthesizer path exercised by this fixture.
export REPOLENS_MIN_SEVERITY=high

init_logging "$run_id" "$RUN_LOG"
init_summary "$SUMMARY_FILE" "$run_id" "$PROJECT_PATH" "bugreport" "$AGENT" "" "" "local" "$TMPDIR/out"

compose_prompt() {
  echo "$3" >> "$COMPOSE_LOG"
  printf 'STUBBED SYNTHESIZER PROMPT'
}

run_agent() {
  echo "fake-agent-call" >> "$AGENT_LOG"
  cat <<'JSON'
[
  {
    "cluster_id": "high::kept",
    "title": "[high] Kept high",
    "severity": "high",
    "domain": "security",
    "lens": "injection",
    "root_cause_category": "injection",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["security"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "low::dropped",
    "title": "[low] Dropped low",
    "severity": "low",
    "domain": "security",
    "lens": "injection",
    "root_cause_category": "injection",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["security"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "medium::dropped",
    "title": "[medium] Dropped medium",
    "severity": "medium",
    "domain": "docs",
    "lens": "readme-quality",
    "root_cause_category": "docs-drift",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["docs"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "missing::dropped",
    "title": "[HIGH] Missing severity",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  },
  {
    "cluster_id": "urgent::dropped",
    "title": "[urgent] Unknown severity",
    "severity": "urgent",
    "domain": "security",
    "lens": "crypto",
    "root_cause_category": "crypto",
    "source_finding_paths": ["logs/run-min-severity-observability/rounds/round-1/lens-outputs/security/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["security"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body"
  }
]
DONE
JSON
}

: > "$COMPOSE_LOG"
: > "$AGENT_LOG"

run_synthesizer "$run_id" >"$TMPDIR/run.out" 2>"$TMPDIR/run.err"
status=$?

summary_file="$SUMMARY_FILE"
unset REPOLENS_MIN_SEVERITY REPOLENS_MODE MODE LOG_BASE SUMMARY_FILE PROJECT_PATH AGENT

log_file="$RUN_LOG/$run_id.log"
manifest="$RUN_LOG/final/manifest.json"
manifest_ids="$(jq -r 'map(.cluster_id) | join(",")' "$manifest" 2>/dev/null || true)"
filtered_count="$(jq -r '.totals.findings_filtered // "missing"' "$summary_file" 2>/dev/null || true)"
agent_calls="$(wc -l < "$AGENT_LOG" | tr -d ' ')"
compose_calls="$(wc -l < "$COMPOSE_LOG" | tr -d ' ')"

assert_success "fake-agent synthesizer run succeeds with min severity high" "$status"
assert_eq "fake agent is invoked exactly once" "1" "$agent_calls"
assert_eq "synthesizer prompt is composed exactly once" "1" "$compose_calls"
assert_file_exists "filtered manifest is promoted" "$manifest"
assert_eq "only high-or-above manifest findings remain" "high::kept" "$manifest_ids"

assert_file_matches "low drop info log has security/injection attribution" "$log_file" '\[INFO\].*\[security/injection\] Dropped finding "\[low\] Dropped low" \(severity=low < min=high\)'
assert_file_matches "medium drop info log has docs/readme-quality attribution" "$log_file" '\[INFO\].*\[docs/readme-quality\] Dropped finding "\[medium\] Dropped medium" \(severity=medium < min=high\)'
assert_file_matches "missing severity warning has code/input-validation attribution" "$log_file" '\[WARN\].*\[code/input-validation\] Finding "\[HIGH\] Missing severity" has invalid severity: "" \(expected critical, high, medium, or low\) - skipping'
assert_file_matches "unknown severity warning has security/crypto attribution" "$log_file" '\[WARN\].*\[security/crypto\] Finding "\[urgent\] Unknown severity" has invalid severity: "urgent" \(expected critical, high, medium, or low\) - skipping'

assert_eq "summary counts every filtered synthesizer finding" "4" "$filtered_count"

direct_summary="$TMPDIR/direct-summary.json"
missing_summary="$TMPDIR/missing-summary.json"
init_summary "$direct_summary" "direct-summary" "$TMPDIR/project" "bugreport" "codex" "" "" "local" "$TMPDIR/out"
initial_direct_count="$(jq -r '.totals.findings_filtered // "missing"' "$direct_summary")"
increment_findings_filtered "$direct_summary"
single_increment_status=$?
increment_findings_filtered "$direct_summary" 3
bulk_increment_status=$?
direct_count="$(jq -r '.totals.findings_filtered // "missing"' "$direct_summary")"
increment_findings_filtered "$direct_summary" "not-a-number"
invalid_increment_status=$?
direct_count_after_invalid="$(jq -r '.totals.findings_filtered // "missing"' "$direct_summary")"
increment_findings_filtered "$missing_summary" 2
missing_increment_status=$?
missing_summary_state="missing"
if [[ -e "$missing_summary" ]]; then
  missing_summary_state="present"
fi

assert_eq "summary helper initializes filtered count" "0" "$initial_direct_count"
assert_success "summary helper increments default count" "$single_increment_status"
assert_success "summary helper increments explicit count" "$bulk_increment_status"
assert_eq "summary helper accumulates filtered counts" "4" "$direct_count"
assert_success "summary helper ignores invalid counts" "$invalid_increment_status"
assert_eq "summary helper leaves count unchanged for invalid input" "4" "$direct_count_after_invalid"
assert_success "summary helper treats missing files as no-op" "$missing_increment_status"
assert_eq "summary helper does not create missing files" "missing" "$missing_summary_state"

finish
