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

# RepoLens — filing batch dispatcher (S4).
#
# Consumes the validated synthesizer manifest at
# logs/<run-id>/final/manifest.json and fans out one filing agent per cluster
# in parallel, with per-cluster lock files for idempotent retry. Re-running on
# a partially-completed batch only fills the gaps.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects beyond loading shared helpers. It expects lib/parallel.sh,
# lib/template.sh, lib/core.sh, lib/forge.sh, and lib/logging.sh to be sourced
# by the caller.
#
# Concurrency contract:
#   The .lock file guards crash-resume re-entry of a SINGLE dispatcher
#   process across runs. It is not a flock — its mtime is the freshness
#   signal, and a stale lock (mtime older than STALE_LOCK_TIMEOUT, default
#   3600s) is treated as a crashed agent and retaken. Two concurrent
#   dispatch_filing_batch invocations on the same run_id may race; the
#   intended invariant is "one dispatcher per run".

# _filing_repo_root
#   Resolves the repository root from this file's location. Used to locate
#   prompts/_base/file-issue.md.
_filing_repo_root() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$(cd "$source_dir/.." && pwd)"
}

# _filing_log_base <run_id>
#   Returns the run log base directory. Honors LOG_BASE when set so callers
#   and tests can redirect output, otherwise falls back to
#   <repo_root>/logs/<run_id>.
_filing_log_base() {
  local run_id="${1:-}"
  if [[ -n "${LOG_BASE:-}" ]]; then
    printf '%s' "$LOG_BASE"
    return 0
  fi
  printf '%s/logs/%s' "$(_filing_repo_root)" "$run_id"
}

# _filing_lock_age <lock_path>
#   Prints the age in seconds of the lock file, or a very large number if
#   the lock file does not exist or its mtime cannot be read. Uses GNU
#   `stat -c %Y` with a BSD `stat -f %m` fallback.
_filing_lock_age() {
  local lock_path="$1"
  local mtime now
  if [[ ! -e "$lock_path" ]]; then
    printf '%s' '999999999'
    return 0
  fi
  mtime="$(stat -c %Y "$lock_path" 2>/dev/null || stat -f %m "$lock_path" 2>/dev/null || printf '0')"
  now="$(date +%s)"
  if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s' '999999999'
    return 0
  fi
  printf '%d' $((now - mtime))
}

# _filing_real_agent <run_id> <cluster_id>
#   Default per-cluster filing callback: composes the file-issue.md prompt
#   for the cluster and invokes the active agent. The agent owns the
#   .url/.failed transition; this callback only cleans up the .lock once
#   one of the terminal markers exists.
#
#   Required globals: AGENT, PROJECT_PATH.
#   Optional globals: REPO_OWNER, REPO_NAME, FORGE_REPO.
_filing_real_agent() {
  local run_id="$1" cluster_id="$2"
  local repo_root log_base manifest filed_dir
  repo_root="$(_filing_repo_root)"
  log_base="$(_filing_log_base "$run_id")"
  manifest="$log_base/final/manifest.json"
  filed_dir="$log_base/final/filed"

  local file_issue_template="$repo_root/prompts/_base/file-issue.md"
  if [[ ! -f "$file_issue_template" ]]; then
    echo "_filing_real_agent: file-issue template missing: $file_issue_template" >&2
    return 1
  fi

  local agent="${AGENT:-}"
  local project_path="${PROJECT_PATH:-}"
  if [[ -z "$agent" ]]; then
    echo "_filing_real_agent: AGENT is not set" >&2
    return 1
  fi
  if [[ -z "$project_path" || ! -d "$project_path" ]]; then
    echo "_filing_real_agent: PROJECT_PATH must be a directory: $project_path" >&2
    return 1
  fi

  if ! declare -F compose_prompt >/dev/null 2>&1; then
    echo "_filing_real_agent: compose_prompt unavailable (source lib/template.sh)" >&2
    return 1
  fi
  if ! declare -F run_agent >/dev/null 2>&1; then
    echo "_filing_real_agent: run_agent unavailable (source lib/core.sh)" >&2
    return 1
  fi

  local entry source_findings
  entry="$(jq -c --arg cid "$cluster_id" \
    '.[] | select(.cluster_id == $cid)' "$manifest" 2>/dev/null)"
  if [[ -z "$entry" ]]; then
    echo "_filing_real_agent: cluster $cluster_id not found in manifest" >&2
    return 1
  fi
  source_findings="$(jq -r --arg cid "$cluster_id" \
    '.[] | select(.cluster_id == $cid) | .source_finding_paths[]' \
    "$manifest" 2>/dev/null)"

  local repo_owner="${REPO_OWNER:-}"
  local repo_name="${REPO_NAME:-}"
  local forge_repo="${FORGE_REPO:-}"
  if [[ -z "$forge_repo" && -n "$repo_owner" && -n "$repo_name" ]]; then
    forge_repo="$repo_owner/$repo_name"
  fi

  local forge_issue_create=""
  local forge_label_create=""
  local forge_issue_list_open=""
  if declare -F forge_prompt_issue_create >/dev/null 2>&1; then
    forge_issue_create="$(forge_prompt_issue_create "<lens-label>" "$forge_repo" "$project_path")"
  fi
  if declare -F forge_prompt_label_create >/dev/null 2>&1; then
    forge_label_create="$(forge_prompt_label_create "<label>" "ededed" "$forge_repo" "$project_path")"
  fi
  if declare -F forge_prompt_issue_list >/dev/null 2>&1; then
    forge_issue_list_open="$(forge_prompt_issue_list "open" "$forge_repo" "$project_path")"
  fi

  # Escape any literal '|' in values that flow through the pipe-delimited
  # vars_string transport accepted by compose_prompt.
  local entry_esc="${entry//\\/\\\\}"
  entry_esc="${entry_esc//|/\\|}"
  local source_findings_esc="${source_findings//\\/\\\\}"
  source_findings_esc="${source_findings_esc//|/\\|}"
  local forge_issue_create_esc="${forge_issue_create//\\/\\\\}"
  forge_issue_create_esc="${forge_issue_create_esc//|/\\|}"
  local forge_label_create_esc="${forge_label_create//\\/\\\\}"
  forge_label_create_esc="${forge_label_create_esc//|/\\|}"
  local forge_issue_list_open_esc="${forge_issue_list_open//\\/\\\\}"
  forge_issue_list_open_esc="${forge_issue_list_open_esc//|/\\|}"

  local vars
  vars="RUN_ID=$run_id"
  vars+="|CLUSTER_ID=$cluster_id"
  vars+="|REPO_OWNER=$repo_owner"
  vars+="|REPO_NAME=$repo_name"
  vars+="|PROJECT_PATH=$project_path"
  vars+="|CLUSTER_MANIFEST_ENTRY=$entry_esc"
  vars+="|SOURCE_FINDINGS=$source_findings_esc"
  vars+="|FORGE_ISSUE_CREATE=$forge_issue_create_esc"
  vars+="|FORGE_LABEL_CREATE=$forge_label_create_esc"
  vars+="|FORGE_ISSUE_LIST_OPEN=$forge_issue_list_open_esc"

  local prompt_text
  prompt_text="$(compose_prompt "$file_issue_template" "$file_issue_template" "$vars")" || {
    echo "_filing_real_agent: prompt composition failed for $cluster_id" >&2
    return 1
  }

  run_agent "$agent" "$prompt_text" "$project_path" >/dev/null || true

  if [[ -e "$filed_dir/$cluster_id.url" || -e "$filed_dir/$cluster_id.failed" ]]; then
    rm -f "$filed_dir/$cluster_id.lock"
    return 0
  fi
  return 1
}

# dispatch_filing_batch <run_id>
#   Consumes logs/<run-id>/final/manifest.json and fans out one filing
#   agent per cluster, in parallel, with per-cluster lock files for
#   idempotent retry. The dispatcher only writes .lock; the filing agent
#   (driven by prompts/_base/file-issue.md) owns the .url/.failed
#   transition.
#
#   Per-cluster state machine for each manifest entry:
#     1. .url present                            -> SKIP (Skipped-existing)
#     2. .failed present                         -> terminal, do not retry
#     3. .lock present, mtime <= STALE_LOCK_TIMEOUT -> SKIP (in flight)
#     4. otherwise                               -> take/refresh .lock and
#                                                   spawn callback
#
#   Returns:
#     0  on completion (whether or not individual callbacks succeeded;
#        callback failures are reflected in the absence of .url/.failed
#        markers and counted in the aggregate output).
#     1  on infrastructure failure: missing manifest, invalid manifest
#        JSON, or a non-array manifest.
#
#   Aggregate output on stdout:
#     Filed: X, Verification-failed: Y, Skipped-existing: Z
#       Filed             = clusters that ended this run with .url and
#                           did not have .url at start.
#       Verification-failed = clusters whose final state is .failed.
#       Skipped-existing  = clusters with pre-existing .url at start.
#
#   Environment overrides:
#     STALE_LOCK_TIMEOUT  Seconds before a .lock is treated as crashed.
#                         Default 3600.
#     MAX_PARALLEL        Max concurrent filing agents. Default 8.
#     LOG_BASE            Override the run log base directory.
#     _FILING_AGENT_CALLBACK
#                         Function name invoked per cluster. Defaults to
#                         _filing_real_agent. Tests inject a stub.
dispatch_filing_batch() {
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "dispatch_filing_batch: missing run_id" >&2
    return 1
  fi

  local log_base manifest final_dir filed_dir stale_lock_timeout
  log_base="$(_filing_log_base "$run_id")"
  manifest="$log_base/final/manifest.json"
  final_dir="$log_base/final"
  filed_dir="$final_dir/filed"
  stale_lock_timeout="${STALE_LOCK_TIMEOUT:-3600}"
  if [[ ! "$stale_lock_timeout" =~ ^[0-9]+$ ]]; then
    stale_lock_timeout=3600
  fi

  if [[ ! -f "$manifest" ]]; then
    echo "dispatch_filing_batch: manifest missing: $manifest" >&2
    return 1
  fi
  if [[ ! -s "$manifest" ]]; then
    echo "dispatch_filing_batch: manifest empty: $manifest" >&2
    return 1
  fi
  if ! jq -e . "$manifest" >/dev/null 2>&1; then
    echo "dispatch_filing_batch: manifest is not valid JSON: $manifest" >&2
    return 1
  fi
  if ! jq -e 'type == "array"' "$manifest" >/dev/null 2>&1; then
    echo "dispatch_filing_batch: manifest top-level is not an array: $manifest" >&2
    return 1
  fi

  local entry_count
  entry_count="$(jq 'length' "$manifest")"
  if (( entry_count == 0 )); then
    printf 'Filed: 0, Verification-failed: 0, Skipped-existing: 0\n'
    return 0
  fi

  mkdir -p "$filed_dir" || {
    echo "dispatch_filing_batch: cannot create filed dir: $filed_dir" >&2
    return 1
  }

  local -a cluster_ids=()
  local cid
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    cluster_ids+=("$cid")
  done < <(jq -r '.[].cluster_id' "$manifest")

  local -A pre_existing_url=()
  local -a to_dispatch=()
  local skipped_existing=0
  local age

  for cid in "${cluster_ids[@]}"; do
    if [[ -e "$filed_dir/$cid.url" ]]; then
      pre_existing_url["$cid"]=1
      skipped_existing=$((skipped_existing + 1))
      continue
    fi
    if [[ -e "$filed_dir/$cid.failed" ]]; then
      # Terminal failure state. Do not retry within this dispatcher
      # invocation; operator must rm the .failed marker to retry.
      continue
    fi
    if [[ -e "$filed_dir/$cid.lock" ]]; then
      age="$(_filing_lock_age "$filed_dir/$cid.lock")"
      if (( age <= stale_lock_timeout )); then
        # Owned by another in-flight worker; skip this cluster.
        continue
      fi
      # Stale lock: fall through and retake.
    fi
    : > "$filed_dir/$cid.lock" || {
      echo "dispatch_filing_batch: failed to take lock for $cid" >&2
      continue
    }
    to_dispatch+=("$cid")
  done

  if (( ${#to_dispatch[@]} > 0 )); then
    if ! declare -F init_parallel >/dev/null 2>&1; then
      echo "dispatch_filing_batch: init_parallel unavailable (source lib/parallel.sh)" >&2
      return 1
    fi
    if ! declare -F spawn_lens >/dev/null 2>&1; then
      echo "dispatch_filing_batch: spawn_lens unavailable (source lib/parallel.sh)" >&2
      return 1
    fi
    if ! declare -F wait_all >/dev/null 2>&1; then
      echo "dispatch_filing_batch: wait_all unavailable (source lib/parallel.sh)" >&2
      return 1
    fi

    local callback="${_FILING_AGENT_CALLBACK:-_filing_real_agent}"
    init_parallel "$log_base/.semaphore" "${MAX_PARALLEL:-8}"
    for cid in "${to_dispatch[@]}"; do
      spawn_lens "$cid" "$callback" "$run_id" "$cid"
    done
    wait_all || true
  fi

  local filed=0 vfailed=0
  for cid in "${cluster_ids[@]}"; do
    if [[ -n "${pre_existing_url[$cid]:-}" ]]; then
      continue
    fi
    if [[ -e "$filed_dir/$cid.url" ]]; then
      filed=$((filed + 1))
    elif [[ -e "$filed_dir/$cid.failed" ]]; then
      vfailed=$((vfailed + 1))
    fi
  done

  printf 'Filed: %d, Verification-failed: %d, Skipped-existing: %d\n' \
    "$filed" "$vfailed" "$skipped_existing"
  return 0
}
