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

# Issue #312 — explicit `.superseded` run-dir marker.
#
# A run dir may be explicitly marked no-longer-authoritative by writing a
# `.superseded` sentinel into logs/<run-id>/. Three behaviours form the
# contract (one acceptance criterion each):
#
#   A. `repolens.sh supersede <run-id>` creates logs/<run-id>/.superseded and
#      rejects ids containing '/', '.', '..', or that are not genuine run dirs,
#      with a nonzero exit and a clear message.
#   B. `repolens.sh status` (no arg) does NOT auto-select a `.superseded` run,
#      even if its status.json is the newest. An explicit `status <id>` still
#      renders a superseded run (only auto-select is affected).
#   C. `repolens.sh clean` removes an otherwise-protected incomplete run once it
#      carries `.superseded`, while a non-superseded incomplete run stays
#      protected and a live/locked run is never removed.
#
# Tests B and C create the `.superseded` marker directly (the same way existing
# clean tests drop `.rate-limit-abort` sentinels) so they isolate the
# honour-the-marker behaviour from the write-the-marker command in Test A.
#
# No real models are invoked — this is entirely fixture- and filesystem-driven,
# reusing the isolated symlink farm from clean_test_lib.sh.

set -uo pipefail

# shellcheck disable=SC1091
# shellcheck source=tests/clean_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean_test_lib.sh"
trap clean_cleanup EXIT

# --- local assertions / runners not provided by clean_test_lib.sh -----------

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "needle='$needle' unexpectedly found"
  fi
}

assert_nonzero() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" != "0" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected nonzero exit, got 0"
  fi
}

assert_nonempty() {
  local desc="$1" val="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -n "$val" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected a non-empty message"
  fi
}

# Marker must be a real regular file: `clean` deletes, so the trigger has to be
# trustworthy, not a symlink or directory.
assert_marker_present() {
  local desc="$1" name="$2"
  TOTAL=$((TOTAL + 1))
  local m="$CLEAN_TEST_LOGS/$name/.superseded"
  if [[ -f "$m" && ! -L "$m" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected regular file logs/$name/.superseded"
  fi
}

# supersede_run / status_run: invoke the real subcommands against the isolated
# farm, capturing stdout/stderr into CLEAN_OUT/CLEAN_ERR (mirrors clean_run).
# stdin is /dev/null so nothing can block on a missing TTY.
supersede_run() {
  local out err rc
  out="$(mktemp)"
  err="$(mktemp)"
  bash "$CLEAN_TEST_FARM/repolens.sh" supersede "$@" </dev/null >"$out" 2>"$err"
  rc=$?
  CLEAN_OUT="$(cat "$out")"
  CLEAN_ERR="$(cat "$err")"
  rm -f "$out" "$err"
  return "$rc"
}

status_run() {
  local out err rc
  out="$(mktemp)"
  err="$(mktemp)"
  bash "$CLEAN_TEST_FARM/repolens.sh" status "$@" </dev/null >"$out" 2>"$err"
  rc=$?
  CLEAN_OUT="$(cat "$out")"
  CLEAN_ERR="$(cat "$err")"
  rm -f "$out" "$err"
  return "$rc"
}

# ===========================================================================
# Test A — `supersede` command: marker creation + validation rejections.
# ===========================================================================
echo "=== supersede: command writes .superseded and validates its id (issue #312) ==="

clean_setup_farm
make_run "20260101T010101Z-supersed0" "finished" "" 60 >/dev/null

supersede_run "20260101T010101Z-supersed0"
rc=$?
assert_eq "supersede on a genuine run dir exits 0" "0" "$rc"
assert_marker_present "supersede writes the .superseded marker" "20260101T010101Z-supersed0"

# The marker is not an empty touch: the atomic write records a `superseded_at=`
# timestamp line, so a later audit / discarded-runs scan can read WHEN it was
# retired. Assert the content, not just the file's existence.
marker_body="$(cat "$CLEAN_TEST_LOGS/20260101T010101Z-supersed0/.superseded")"
assert_contains "supersede marker records a superseded_at timestamp" \
  "superseded_at=" "$marker_body"

# Path-traversal ids must be rejected BEFORE any path is built (same guard as
# status_resolve_file): nonzero exit, clear message, nothing created.
supersede_run "foo/bar"
rc=$?
assert_nonzero "supersede rejects an id containing '/'" "$rc"
assert_nonempty "supersede prints a message when rejecting '/'" "$CLEAN_ERR"

supersede_run "."
assert_nonzero "supersede rejects '.'" "$?"

supersede_run ".."
assert_nonzero "supersede rejects '..'" "$?"

# Well-formed run-id shape but no such dir -> _clean_is_run_dir fails.
supersede_run "20260101T010101Z-doesnotexist"
rc=$?
assert_nonzero "supersede rejects a well-formed id with no run dir" "$rc"
assert_dir_absent "supersede does not fabricate a dir for a missing run" "20260101T010101Z-doesnotexist"

# Non-run-shaped name -> regex fails.
supersede_run "not-a-run-id"
assert_nonzero "supersede rejects a non-run-shaped id" "$?"

# Missing argument.
supersede_run
assert_nonzero "supersede with no run id exits nonzero" "$?"

# `-h`/`--help` is a VALID invocation: print usage and exit 0. This is a
# distinct branch from the missing-arg error path (which exits nonzero), so it
# needs its own coverage.
supersede_run --help
rc=$?
assert_eq "supersede --help exits 0" "0" "$rc"
assert_contains "supersede --help prints its usage" \
  "Usage: repolens.sh supersede" "$CLEAN_OUT"

supersede_run -h
assert_eq "supersede -h exits 0" "0" "$?"

# ===========================================================================
# Test B — `status` (no arg) skips a `.superseded` run; explicit id still works.
# status_command requires jq, so guard the whole group on jq availability.
# ===========================================================================
if command -v jq >/dev/null 2>&1; then
  echo "=== status: no-arg auto-select skips .superseded runs (issue #312) ==="

  clean_cleanup
  clean_setup_farm
  make_run "20260101T020000Z-normal000" "finished" "" 1 >/dev/null
  make_run "20260101T030000Z-retired00" "finished" "" 1 >/dev/null

  # Mark the retired run, then make ITS status.json the newest so that, without
  # the skip, no-arg status would pick it. status_latest_file keys off the
  # status.json file mtime (not dir mtime), so stamp those files explicitly.
  printf 'superseded_at=test\n' > "$CLEAN_TEST_LOGS/20260101T030000Z-retired00/.superseded"
  now_epoch="$(date -u +%s)"
  touch -d "@$(( now_epoch - 100 ))" "$CLEAN_TEST_LOGS/20260101T020000Z-normal000/status.json"
  touch -d "@$now_epoch"             "$CLEAN_TEST_LOGS/20260101T030000Z-retired00/status.json"

  status_run
  rc=$?
  assert_eq "status no-arg exits 0 when a live run remains" "0" "$rc"
  assert_contains "status no-arg selects the non-superseded run" \
    "20260101T020000Z-normal000" "$CLEAN_OUT"
  assert_not_contains "status no-arg skips the superseded newest run" \
    "20260101T030000Z-retired00" "$CLEAN_OUT"

  # Explicit id still renders a superseded run — only auto-select is affected.
  status_run "20260101T030000Z-retired00"
  rc=$?
  assert_eq "status <superseded-id> still exits 0" "0" "$rc"
  assert_contains "status <superseded-id> still renders that run" \
    "20260101T030000Z-retired00" "$CLEAN_OUT"

  # When the ONLY run is superseded, no-arg status finds nothing to show.
  clean_cleanup
  clean_setup_farm
  make_run "20260101T040000Z-onlyretd" "finished" "" 1 >/dev/null
  printf 'superseded_at=test\n' > "$CLEAN_TEST_LOGS/20260101T040000Z-onlyretd/.superseded"

  status_run
  rc=$?
  assert_nonzero "status no-arg with only a superseded run finds nothing" "$rc"
  assert_contains "status reports no status files when all runs are superseded" \
    "No RepoLens status files found" "$CLEAN_ERR"
else
  echo "  SKIP: jq not available — status auto-select skip test skipped"
fi

# ===========================================================================
# Test C — `clean` honours `.superseded`: removes an otherwise-protected
# incomplete run, spares a non-superseded incomplete run, never removes a
# live/locked run.
# ===========================================================================
echo "=== clean: .superseded overrides keep-incomplete but not the lock guard (issue #312) ==="

clean_cleanup
clean_setup_farm

# Superseded + incomplete (state=interrupted): the supersede marker overrides
# the default keep-incomplete protection, so this run becomes removable.
sup_dir="$(make_run "20260101T050000Z-supincmp0" "interrupted" "" 60)"
printf 'superseded_at=test\n' > "$sup_dir/.superseded"
# Writing the marker bumped the dir mtime back to "now"; re-stamp it old so the
# age guard does not protect it (mtime must be set last — see make_run).
touch -d "@$(epoch_days_ago 60)" "$sup_dir"

# Control: incomplete but NOT superseded -> default keep-incomplete protects it.
make_run "20260101T050001Z-keepincmp" "interrupted" "" 60 >/dev/null

# Note: NO --remove-incomplete. Default keep-incomplete is ON.
clean_run --older-than 1d --keep-last 0 --force
rc=$?
assert_eq "clean sweep exits 0" "0" "$rc"
assert_dir_absent  "clean removes a superseded incomplete run" "20260101T050000Z-supincmp0"
assert_dir_present "clean still protects a non-superseded incomplete run" "20260101T050001Z-keepincmp"

# Locked + superseded + incomplete: the lock guard wins. A run that is BOTH a
# resume candidate AND superseded must still survive while a live process holds
# its .repolens.flock — supersede overrides keep-incomplete, never the lock.
if command -v flock >/dev/null 2>&1; then
  clean_cleanup
  clean_setup_farm
  locked_dir="$(make_run "20260101T060000Z-suplocked" "interrupted" "" 60)"
  printf 'superseded_at=test\n' > "$locked_dir/.superseded"
  : > "$locked_dir/.repolens.flock"
  # Re-stamp old AFTER creating marker + lock file so only the lock can protect it.
  touch -d "@$(epoch_days_ago 60)" "$locked_dir"

  lock_file="$locked_dir/.repolens.flock"
  exec {hold_fd}>"$lock_file"
  flock -n "$hold_fd"
  (
    exec {bg_fd}>"$lock_file"
    flock -n "$bg_fd" || true   # already held by parent; keep the file busy
    sleep 5
  ) &
  bg_pid=$!

  clean_run --older-than 1d --keep-last 0 --force
  rc=$?

  exec {hold_fd}>&-
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true

  assert_eq "clean exits 0 while a superseded run is locked" "0" "$rc"
  assert_dir_present "clean never removes a live/locked run even when superseded" \
    "20260101T060000Z-suplocked"
else
  echo "  SKIP: flock not available — locked superseded guard test skipped"
fi

# ===========================================================================
# Test D — hardening + end-to-end. `clean` DELETES, so its supersede override
# trusts ONLY a regular, non-symlink `.superseded` file (the `! -L` asymmetry
# vs `status`, which merely hides via `-e`). And the real `supersede` command's
# marker must be honoured by `clean` end-to-end, not just a hand-dropped one.
# ===========================================================================
echo "=== clean: symlinked .superseded is not trusted; supersede->clean works end-to-end (issue #312) ==="

clean_cleanup
clean_setup_farm

# A SYMLINK named `.superseded` — pointed at a real regular file so that a naive
# `-f` check (without `! -L`) WOULD follow it and wrongly treat the run as
# superseded. The hardening must keep this incomplete run protected: a stray or
# malicious symlink must never trigger deletion of a resume candidate.
sym_dir="$(make_run "20260101T070000Z-symmarker" "interrupted" "" 60)"
ln -s status.json "$sym_dir/.superseded"   # resolves to the dir's real status.json
touch -d "@$(epoch_days_ago 60)" "$sym_dir"

# End-to-end: retire a run via the REAL `supersede` command (not a hand-dropped
# marker), then `clean` must remove this otherwise-protected incomplete run —
# proving the writer's marker is byte-compatible with clean's honour path.
e2e_dir="$(make_run "20260101T070001Z-e2eincmp0" "interrupted" "" 60)"
supersede_run "20260101T070001Z-e2eincmp0"
rc=$?
assert_eq "supersede command succeeds in the end-to-end fixture" "0" "$rc"
# Re-stamp old AFTER the command wrote the marker (it bumped the dir mtime).
touch -d "@$(epoch_days_ago 60)" "$e2e_dir"

clean_run --older-than 1d --keep-last 0 --force
rc=$?
assert_eq "clean sweep (symlink + e2e) exits 0" "0" "$rc"
assert_dir_present "clean does NOT trust a symlinked .superseded marker" \
  "20260101T070000Z-symmarker"
assert_dir_absent "clean removes a run retired via the real supersede command" \
  "20260101T070001Z-e2eincmp0"

clean_finish
