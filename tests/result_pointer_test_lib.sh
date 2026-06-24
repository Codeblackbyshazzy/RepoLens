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

# Shared fixtures harness for the result-pointer feature (issue #318).
#
# The result-pointer siblings (#308 latest-result.json core, #310 discarded_runs,
# #312 .superseded marker, #313 LATEST symlink) each need the SAME deterministic
# `logs/` tree to exercise lib/result_pointer.sh against — a "current" run, an
# incomplete run, an empty run, a prior complete run, and a non-run dir — without
# hand-rolling one per test and WITHOUT ever invoking a real model.
#
# This file is a *sourced* helper (note the `_test_lib.sh` suffix, NOT a
# `test_*.sh` name, so tests/run-all.sh does not try to run it as a suite). It
# follows the symlink-farm isolation pattern from tests/clean_test_lib.sh: a
# throwaway temp dir under /tmp that symlinks repolens.sh / lib / config /
# prompts back to the real tree but owns its OWN `logs/` directory. The pointer
# functions are then sourced and called directly against that farm's logs dir,
# so nothing ever writes to the real repo `logs/`.
#
# It also exposes a small set of assertion helpers (matching the convention in
# clean_test_lib.sh) so the smoke test — and future sibling tests that adopt this
# harness — do not re-declare them.
#
# Determinism: every run-id and timestamp here is FIXED (no `date`-derived
# values). Pointer classification is age-independent (unlike clean.sh retention),
# so a byte-reproducible tree is both possible and preferable.

# Repo root, resolved relative to this file regardless of cwd.
RP_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Production-parity sourcing order: core -> logging -> clean -> result_pointer.
# clean.sh defines the _clean_* predicates _collect_discarded_runs relies on;
# omit it and discarded_runs silently degrades to [].
RP_CORE_LIB="$RP_TEST_ROOT/lib/core.sh"
RP_LOG_LIB="$RP_TEST_ROOT/lib/logging.sh"
RP_CLEAN_LIB="$RP_TEST_ROOT/lib/clean.sh"
RP_LIB="$RP_TEST_ROOT/lib/result_pointer.sh"

RP_FIXTURES_DIR="$RP_TEST_ROOT/tests/fixtures"
RP_MANIFEST_FIXTURE="$RP_FIXTURES_DIR/manifest_with_severities.json"

# Fixed, regex-valid run-ids for the canonical tree (all match
# lib/clean.sh's _CLEAN_RUN_ID_REGEX = ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$).
RP_RUN_CURRENT="20260601T000000Z-cur00000"     # authoritative run (current)
RP_RUN_INCOMPLETE="20260601T010000Z-abort001"  # abort sentinel -> aborted-or-incomplete
RP_RUN_EMPTY="20260601T020000Z-empty002"       # status only, no final -> empty
RP_RUN_PRIOR="20260601T030000Z-prior003"       # final/manifest.json -> superseded

# Assertion/bookkeeping state (shared with sourcing suites).
PASS=0
FAIL=0
TOTAL=0

# Farm + scratch state, populated by rp_setup_farm / rp_run_pointer.
RP_TEST_FARM=""
RP_TEST_LOGS=""
RP_UNIT_ERR=""

# ---------------------------------------------------------------------------
# Assertion helpers (names match clean_test_lib.sh / sibling tests).
# ---------------------------------------------------------------------------

record_pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  FAIL=$((FAIL + 1))
  if [[ -n "${2:-}" ]]; then
    echo "  FAIL: $1 ($2)"
  else
    echo "  FAIL: $1"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected='$expected' actual='${actual:-<empty>}'"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected file at $file"
  fi
}

# assert_present <desc> <path> — path exists (file, dir, or symlink).
assert_present() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -e "$path" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected $path to exist"
  fi
}

# assert_absent <desc> <path> — path does NOT exist.
assert_absent() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected $path to be absent"
  fi
}

# assert_jq_true <desc> <file> <filter> — filter must be truthy under jq -e.
assert_jq_true() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    record_pass "$desc"
  else
    record_fail "$desc" "jq filter not truthy: $filter (file: $file)"
  fi
}

# assert_jq_eq <desc> <file> <filter> <expected>
assert_jq_eq() {
  local desc="$1" file="$2" filter="$3" expected="$4" actual
  TOTAL=$((TOTAL + 1))
  actual="$(jq -r "$filter" "$file" 2>/dev/null || printf '__jq_error__')"
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected='$expected' actual='${actual:-<empty>}' filter='$filter'"
  fi
}

# rp_require_jq — emit a clean SKIP + a passing Results line and exit 0 if jq is
# missing. counts/discarded_runs and the _clean_* predicates all depend on jq, so
# without it the harness cannot assert anything meaningful.
rp_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq not available — result-pointer fixtures harness needs jq"
    echo ""
    echo "Results: 0/0 passed, 0 failed"
    exit 0
  fi
}

# rp_finish — print the runner-parsed Results line and exit (1 on any failure).
rp_finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  [[ "$FAIL" -gt 0 ]] && exit 1
  exit 0
}

# ---------------------------------------------------------------------------
# Farm lifecycle.
# ---------------------------------------------------------------------------

# rp_setup_farm — build an isolated symlink farm under /tmp with its own empty
# logs dir. Sets RP_TEST_FARM and RP_TEST_LOGS. The farm lives OUTSIDE the repo
# tree so nothing here can touch the real `logs/` (AC#1).
rp_setup_farm() {
  RP_TEST_FARM="$(mktemp -d)"
  local item
  for item in repolens.sh lib config prompts; do
    ln -s "$RP_TEST_ROOT/$item" "$RP_TEST_FARM/$item"
  done
  RP_TEST_LOGS="$RP_TEST_FARM/logs"
  mkdir -p "$RP_TEST_LOGS"
}

# rp_cleanup — remove the farm (guarded). Intended for `trap rp_cleanup EXIT`.
# shellcheck disable=SC2329  # invoked indirectly via trap in sourcing suites.
rp_cleanup() {
  [[ -n "$RP_TEST_FARM" && -d "$RP_TEST_FARM" ]] && rm -rf "$RP_TEST_FARM"
}

# ---------------------------------------------------------------------------
# Seed helpers — build run dirs the clean selector recognizes.
# ---------------------------------------------------------------------------

# rp_seed_run <dir> <state> <stopped_reason_json> <issues_created>
# Build a genuine run dir: status.json (.state) + summary.json
# (.stopped_reason, .totals.issues_created, fixed ISO timestamps). The dir
# basename is used as run_id. <stopped_reason_json> must be a JSON literal:
# `null` or `"some-reason"`. Generalizes seed_run from
# tests/test_latest_result_discarded.sh.
rp_seed_run() {
  local dir="$1" state="$2" stopped="$3" issues="$4" name="${1##*/}"
  mkdir -p "$dir"
  printf '{"run_id":"%s","state":"%s","updated_at":"2026-06-01T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}\n' \
    "$name" "$state" > "$dir/status.json"
  printf '{"run_id":"%s","stopped_reason":%s,"totals":{"issues_created":%s},"started_at":"2026-06-01T00:00:00Z","completed_at":"2026-06-01T01:00:00Z"}\n' \
    "$name" "$stopped" "$issues" > "$dir/summary.json"
}

# rp_seed_status_only <dir> <state> — a run dir with status.json ONLY (no
# summary.json, no final/). A finished status-only run with zero issues and no
# manifest classifies as "empty".
rp_seed_status_only() {
  local dir="$1" state="$2" name="${1##*/}"
  mkdir -p "$dir"
  printf '{"run_id":"%s","state":"%s","updated_at":"2026-06-01T00:00:00Z","started_at":"2026-06-01T00:00:00Z"}\n' \
    "$name" "$state" > "$dir/status.json"
}

# rp_seed_final_manifest <dir> [fixture] — create <dir>/final/ and copy the
# mixed-severity fixture (default manifest_with_severities.json) into
# <dir>/final/manifest.json so severity `counts` is exercised. Presence of the
# manifest file is also what makes _collect_discarded_runs classify the run as
# "superseded" rather than "empty".
rp_seed_final_manifest() {
  local dir="$1" fixture="${2:-$RP_MANIFEST_FIXTURE}"
  mkdir -p "$dir/final"
  cp "$fixture" "$dir/final/manifest.json"
}

# rp_seed_abort <dir> [sentinel] — drop an abort sentinel (default
# .rate-limit-abort) so _clean_is_incomplete classifies the run as
# aborted-or-incomplete.
rp_seed_abort() {
  local dir="$1" sentinel="${2:-.rate-limit-abort}"
  touch "$dir/$sentinel"
}

# rp_build_tree <logs_dir> — assemble the full canonical fixtures tree:
#   RP_RUN_CURRENT    — summary+status + final/manifest.json (the current run)
#   RP_RUN_INCOMPLETE — summary+status + .rate-limit-abort sentinel
#   RP_RUN_EMPTY      — status.json ONLY (no summary, no final/, 0 issues)
#   RP_RUN_PRIOR      — summary+status + final/manifest.json (a complete run)
#   issues/           — a non-run dir whose name fails the run-id regex
rp_build_tree() {
  local logs_dir="$1"
  mkdir -p "$logs_dir"

  # Current authoritative run: finished, with a manifest to drive counts.
  rp_seed_run "$logs_dir/$RP_RUN_CURRENT" "finished" "null" "0"
  rp_seed_final_manifest "$logs_dir/$RP_RUN_CURRENT"

  # Incomplete: finished state, but an abort sentinel forces the
  # aborted-or-incomplete classification (isolates that path).
  rp_seed_run "$logs_dir/$RP_RUN_INCOMPLETE" "finished" "null" "0"
  rp_seed_abort "$logs_dir/$RP_RUN_INCOMPLETE"

  # Empty: status.json only — no summary, no final/, zero issues.
  rp_seed_status_only "$logs_dir/$RP_RUN_EMPTY" "finished"

  # Prior complete run: finalized with a manifest present (and issues).
  rp_seed_run "$logs_dir/$RP_RUN_PRIOR" "finished" "null" "2"
  rp_seed_final_manifest "$logs_dir/$RP_RUN_PRIOR"

  # Non-run dir: an AutoDev-style 'issues/' dir whose name fails the run-id
  # regex, so the run-dir filter excludes it by construction.
  mkdir -p "$logs_dir/issues"
  printf '{"state":"whatever"}\n' > "$logs_dir/issues/state.json"
}

# ---------------------------------------------------------------------------
# Driver — call write_latest_result_pointer against the farm, model-free.
# ---------------------------------------------------------------------------

# rp_run_pointer <logs_dir> <run_id> <summary_file> <status> <final_dir>
# Source core -> logging -> clean -> result_pointer in an isolated shell and call
# write_latest_result_pointer with the documented signature. Sourcing clean.sh is
# what makes discarded_runs non-empty (production parity: repolens.sh sources
# clean.sh before result_pointer.sh). mode/agent are fixed literals — NO model is
# ever invoked. stderr is captured to RP_UNIT_ERR. Returns the helper's rc (0 on
# every path; the helper is strictly non-fatal). Lifted from the proven wrapper
# in tests/test_latest_result_discarded.sh.
rp_run_pointer() {
  local logs_dir="$1" run_id="$2" summary_file="$3" status="$4" final_dir="$5"
  RP_UNIT_ERR="$(mktemp)"
  bash -c '
    set -uo pipefail
    source "$1"   # core.sh           (severity_normalize)
    source "$2"   # logging.sh        (log_warn)
    source "$3"   # clean.sh          (_clean_is_run_dir / _clean_is_incomplete / _clean_is_locked)
    source "$4"   # result_pointer.sh (function under test)
    write_latest_result_pointer "$5" "$6" "audit" "codex" "$7" "$8" "$9"
  ' _ "$RP_CORE_LIB" "$RP_LOG_LIB" "$RP_CLEAN_LIB" "$RP_LIB" \
    "$logs_dir" "$run_id" "$summary_file" "$status" "$final_dir" \
    2>"$RP_UNIT_ERR"
  return $?
}
