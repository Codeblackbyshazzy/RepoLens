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

# RepoLens - round-aware lens execution driver

# run_rounds <rounds_total> <lens_list_array_name>
#   Runs the current per-lens dispatch path for rounds 1..rounds_total.
#   The second argument is the name of a Bash array, for example LENS_LIST.
#   This deliberately avoids Bash namerefs so the module stays compatible
#   with the project's Bash 4 baseline.
#
#   Required globals are provided by repolens.sh when R4 wires this in:
#   PARALLEL, MAX_PARALLEL, LOG_BASE, SUMMARY_FILE, MAX_ISSUES,
#   GLOBAL_ISSUES_CREATED, and TOTAL_LENSES.
#
#   R1 only validates the round count; it does not define per-round issue
#   budgets. Keep GLOBAL_ISSUES_CREATED cumulative across rounds until that
#   contract changes.

_rounds_valid_array_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

_rounds_marker_path() {
  local round="$1"
  printf '%s/.rounds/round-%s.completed\n' "$LOG_BASE" "$round"
}

_rounds_lens_completion_path() {
  local round="$1"
  printf '%s/.rounds/round-%s.lenses.completed\n' "$LOG_BASE" "$round"
}

_rounds_restore_completed_lenses_file() {
  local had_completed_file="$1" original_completed_file="$2"

  if (( had_completed_file )); then
    completed_lenses_file="$original_completed_file"
  else
    unset completed_lenses_file
  fi
}

is_round_completed() {
  local round="$1"
  local marker
  marker="$(_rounds_marker_path "$round")"
  [[ -f "$marker" ]]
}

mark_round_completed() {
  local round="$1"
  local marker marker_dir
  marker="$(_rounds_marker_path "$round")"
  marker_dir="${marker%/*}"
  mkdir -p "$marker_dir"
  : > "$marker"
}

run_meta_orchestrator() {
  local round="$1" next_round="$2"
  log_info "[round $round] Meta-orchestrator handoff to round $next_round is pending implementation"
  return 0
}

_rounds_record_skipped_lenses() {
  local skip_entry skip_domain skip_lens

  for skip_entry in "$@"; do
    skip_domain="${skip_entry%%/*}"
    skip_lens="${skip_entry#*/}"
    if ! is_lens_completed "$skip_entry"; then
      record_lens "$SUMMARY_FILE" "$skip_domain" "$skip_lens" 0 "skipped" 0 0
    fi
  done
}

run_rounds() {
  local rounds_total="$1" lens_list_var="$2"
  local -a lens_list=()
  local round lens_entry parallel_count local_count lens_total
  local original_completed_lenses_file had_completed_lenses_file
  local round_completed_lenses_file round_completed_lenses_dir round_rc

  if [[ ! "$rounds_total" =~ ^[1-9][0-9]*$ ]]; then
    log_warn "Invalid rounds_total: $rounds_total"
    return 2
  fi
  if ! _rounds_valid_array_name "$lens_list_var"; then
    log_warn "Invalid lens list array name: $lens_list_var"
    return 2
  fi

  eval "lens_list=(\"\${${lens_list_var}[@]}\")"
  lens_total="${TOTAL_LENSES:-${#lens_list[@]}}"

  # shellcheck disable=SC2046 # The issue explicitly requires seq-driven rounds.
  for round in $(seq 1 "$rounds_total"); do
    if is_round_completed "$round"; then
      log_info "[round $round/$rounds_total] Skipping completed round"
      continue
    fi

    if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
      set_stop_reason "$SUMMARY_FILE" "rate-limited"
      return 1
    fi

    if (( rounds_total > 1 )); then
      log_info "[round $round/$rounds_total] Starting"
    fi

    had_completed_lenses_file=0
    original_completed_lenses_file="${completed_lenses_file:-}"
    if [[ ${completed_lenses_file+x} == x ]]; then
      had_completed_lenses_file=1
    fi

    if (( rounds_total > 1 )); then
      round_completed_lenses_file="$(_rounds_lens_completion_path "$round")"
      round_completed_lenses_dir="${round_completed_lenses_file%/*}"
      if ! mkdir -p "$round_completed_lenses_dir" || ! touch "$round_completed_lenses_file"; then
        _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
        return 1
      fi
      completed_lenses_file="$round_completed_lenses_file"
    fi

    if ${PARALLEL:-false}; then
      log_info "Running in parallel mode (max ${MAX_PARALLEL:-8} concurrent)"
      init_parallel "$LOG_BASE/.semaphore" "${MAX_PARALLEL:-8}"

      parallel_count=0
      for lens_entry in "${lens_list[@]}"; do
        # Skip spawning new lenses if a sibling tripped the rate-limit detector.
        # In-flight children continue; the summary still records skipped lenses
        # so --resume picks them up.
        if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
          log_warn "Rate-limit abort detected. Skipping remaining lenses."
          _rounds_record_skipped_lenses "${lens_list[@]:$parallel_count}"
          set_stop_reason "$SUMMARY_FILE" "rate-limited"
          break
        fi
        parallel_count=$((parallel_count + 1))
        spawn_lens "$lens_entry" run_lens "$lens_entry"
      done

      if ! wait_all; then
        log_warn "Some lenses exited with errors."
      fi

      # Children may have tripped the abort after the spawn loop finished.
      # Make sure the stop_reason is recorded even then.
      if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
        set_stop_reason "$SUMMARY_FILE" "rate-limited"
      fi
    else
      log_info "Running in sequential mode"
      local_count=0
      for lens_entry in "${lens_list[@]}"; do
        # Check for rate-limit abort from a previous lens in this run.
        if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
          log_warn "Rate-limit abort detected. Skipping remaining lenses."
          _rounds_record_skipped_lenses "${lens_list[@]:$local_count}"
          set_stop_reason "$SUMMARY_FILE" "rate-limited"
          break
        fi

        # Check global issue budget before starting next lens.
        if [[ -n "${MAX_ISSUES:-}" && "${GLOBAL_ISSUES_CREATED:-0}" -ge "$MAX_ISSUES" ]]; then
          log_info "Global issue budget exhausted (${GLOBAL_ISSUES_CREATED:-0}/$MAX_ISSUES). Skipping remaining lenses."
          _rounds_record_skipped_lenses "${lens_list[@]:$local_count}"
          set_stop_reason "$SUMMARY_FILE" "max-issues-reached"
          break
        fi

        local_count=$((local_count + 1))
        log_info "--- Lens $local_count/$lens_total ---"
        run_lens "$lens_entry"
      done
    fi

    if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
      set_stop_reason "$SUMMARY_FILE" "rate-limited"
      _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
      return 1
    fi

    mark_round_completed "$round"
    round_rc=$?
    _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
    if (( round_rc != 0 )); then
      return "$round_rc"
    fi

    if (( round < rounds_total )); then
      run_meta_orchestrator "$round" "$((round + 1))" || return $?
    fi
  done
}
