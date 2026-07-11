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

# filing_verify_cluster_citations <project_path> <manifest_entry_json>
#   Deterministic re-verification of every `path:LINE` (or `path:LSTART-LEND`)
#   citation embedded in a synthesizer manifest entry's `body` field. This is
#   the executable counterpart of Step 2 in prompts/_base/file-issue.md and is
#   intended as the last shell-level guardrail before a cluster can reach
#   `gh issue create`. Filing callbacks (production or test) may call this
#   helper to decide whether to write a `.url` or a `VERIFICATION_FAILED:`
#   `.failed` sentinel.
#
#   Citation grammar (extracted from the manifest entry's `body` string):
#     - `path:LINE`               (single-line citation)
#     - `path:LSTART-LEND`        (line-range citation; LSTART <= LEND)
#     - Optionally followed by a backtick-fenced snippet on the same logical
#       line, e.g. `src/auth.sh:42 — \`return $LOGIN_DENIED\`` — when present,
#       the snippet text must appear within +/-20 lines of the cited line.
#
#   For each citation:
#     1. The cited file must exist under <project_path>.
#     2. The cited line (or LSTART..LEND range) must lie within the file's
#        line count. LSTART > line_count -> MISMATCH "line exceeds file
#        length".
#     3. If a backtick snippet is attached, the snippet text must be findable
#        (substring match) within +/-20 lines of the cited line. Snippet not
#        found -> MISMATCH "snippet not found near cited line".
#
#   On success: returns 0. Prints nothing.
#   On failure: returns 1. Prints exactly one concise reason line on stdout
#               of the form `<path>:<line> <description>` so callers can
#               embed it verbatim after `VERIFICATION_FAILED: `.
#
#   If the body contains zero parseable citations the helper treats that as a
#   verification failure ("no citations to verify"), matching the prompt rule
#   that an issue must be backed by at least one verified citation.
filing_verify_cluster_citations() {
  local project_path="${1:-}"
  local entry_json="${2:-}"
  if [[ -z "$project_path" || ! -d "$project_path" ]]; then
    printf 'project path missing or not a directory: %s\n' "$project_path"
    return 1
  fi
  if [[ -z "$entry_json" ]]; then
    printf 'manifest entry json is empty\n'
    return 1
  fi

  local body
  body="$(jq -r '.body // empty' <<<"$entry_json" 2>/dev/null)"
  if [[ -z "$body" ]]; then
    printf 'manifest entry has no body to verify citations against\n'
    return 1
  fi

  # Extract citations of the form `path:N` or `path:N-M`. The path component
  # accepts letters/digits/_/-/./ slash, must contain at least one '/' or
  # '.' to avoid trapping things like `step:1`, and the line number must be
  # numeric. Use a temporary while loop with grep -oE so each match is
  # processed independently.
  local citations
  citations="$(grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9_-]+:[0-9]+(-[0-9]+)?' <<<"$body" \
    | sort -u)"

  if [[ -z "$citations" ]]; then
    printf 'no citations found in body\n'
    return 1
  fi

  local citation path line_spec lstart lend file_path line_count snippet
  local snippet_pattern context_start context_end
  while IFS= read -r citation; do
    [[ -n "$citation" ]] || continue
    path="${citation%:*}"
    line_spec="${citation##*:}"
    if [[ "$line_spec" == *-* ]]; then
      lstart="${line_spec%-*}"
      lend="${line_spec#*-}"
    else
      lstart="$line_spec"
      lend="$line_spec"
    fi
    if ! [[ "$lstart" =~ ^[0-9]+$ ]] || ! [[ "$lend" =~ ^[0-9]+$ ]]; then
      printf '%s invalid line spec\n' "$citation"
      return 1
    fi
    if (( lstart < 1 )) || (( lend < lstart )); then
      printf '%s invalid line range\n' "$citation"
      return 1
    fi

    file_path="$project_path/$path"
    if [[ ! -f "$file_path" ]]; then
      printf '%s file not found\n' "$citation"
      return 1
    fi
    line_count="$(wc -l <"$file_path" | tr -d ' ')"
    # Treat a final line without a trailing newline as a real line.
    if [[ -s "$file_path" ]] && [[ "$(tail -c 1 "$file_path" | od -An -c | tr -d ' ')" != '\n' ]]; then
      line_count=$((line_count + 1))
    fi
    if (( lstart > line_count )) || (( lend > line_count )); then
      printf '%s line exceeds file length (%d lines)\n' "$citation" "$line_count"
      return 1
    fi

    # Optional snippet check: look for a backtick-quoted snippet attached to
    # this citation on the same logical body line. Use grep on the body so
    # multi-line bodies are searched line-by-line.
    snippet="$(grep -F "$citation" <<<"$body" \
      | grep -oE "\`[^\`]+\`" \
      | head -1 \
      | sed -e 's/^`//' -e 's/`$//')"
    if [[ -n "$snippet" ]]; then
      context_start=$(( lstart - 20 ))
      (( context_start < 1 )) && context_start=1
      context_end=$(( lend + 20 ))
      (( context_end > line_count )) && context_end=$line_count
      snippet_pattern="$(sed -n "${context_start},${context_end}p" "$file_path")"
      if [[ "$snippet_pattern" != *"$snippet"* ]]; then
        printf '%s snippet not found near cited line\n' "$citation"
        return 1
      fi
    fi
  done <<< "$citations"

  return 0
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
  local filed_dir_esc="${filed_dir//\\/\\\\}"
  filed_dir_esc="${filed_dir_esc//|/\\|}"

  local vars
  vars="RUN_ID=$run_id"
  vars+="|CLUSTER_ID=$cluster_id"
  vars+="|REPO_OWNER=$repo_owner"
  vars+="|REPO_NAME=$repo_name"
  vars+="|PROJECT_PATH=$project_path"
  vars+="|CLUSTER_MANIFEST_ENTRY=$entry_esc"
  vars+="|SOURCE_FINDINGS=$source_findings_esc"
  vars+="|FILED_DIR=$filed_dir_esc"
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

# _filing_cross_link_enact <run_id>
#   Iterate every manifest entry's cross_link_actions[] and enact them via
#   the forge layer. Idempotent: each (type, issue_number) pair is keyed by
#   a content-hash sentinel under final/filed/cross-link/, so re-running the
#   dispatcher does not re-enact already-completed actions.
#
#   Per-action state machine for each cross-link entry:
#     1. <key>.done present     -> SKIP
#     2. <key>.failed present   -> SKIP (operator must rm to retry)
#     3. otherwise              -> attempt; on success write .done; on
#                                  failure write .failed (non-fatal)
#
#   Failures NEVER fail the overall run — cross-link actions are best-effort.
#   They are logged to stderr and counted in the run's diagnostics only.
#
#   Required globals: AGENT, FORGE_REPO (or REPO_OWNER+REPO_NAME).
#   Optional globals: REPOLENS_REOPEN_LABEL (defaults "repolens:reopen-candidate").
#
#   Cross-link actions on a cluster whose own filing failed
#   (<cid>.failed present, no <cid>.url) are skipped to avoid posting a
#   cross-link comment that references a non-existent new issue.
_filing_cross_link_enact() {
  local run_id="${1:-}"
  local log_base manifest preserved_actions verification filed_dir cross_dir
  log_base="$(_filing_log_base "$run_id")"
  manifest="$log_base/final/manifest.json"
  preserved_actions="$log_base/final/cross-link-actions.preserved.json"
  verification="$log_base/final/verification.json"
  filed_dir="$log_base/final/filed"
  cross_dir="$filed_dir/cross-link"

  if [[ ! -f "$manifest" && ! -f "$preserved_actions" ]]; then
    return 0
  fi

  local repo_owner="${REPO_OWNER:-}"
  local repo_name="${REPO_NAME:-}"
  local forge_repo="${FORGE_REPO:-}"
  if [[ -z "$forge_repo" && -n "$repo_owner" && -n "$repo_name" ]]; then
    forge_repo="$repo_owner/$repo_name"
  fi
  local reopen_label="${REPOLENS_REOPEN_LABEL:-repolens:reopen-candidate}"

  # Build a flat list of (cluster_id, idx, type, issue_number, body) tuples.
  local tuples manifest_tuples preserved_tuples verification_json
  manifest_tuples=""
  preserved_tuples=""
  verification_json='[]'
  if [[ -f "$manifest" ]]; then
    manifest_tuples="$(jq -r '
      to_entries[]
      | .key as $i
      | .value.cluster_id as $cid
      | (.value.cross_link_actions // [])
      | to_entries[]
      | [$cid, .key, .value.type, (.value.issue_number | tostring), .value.body]
      | @tsv
    ' "$manifest" 2>/dev/null)" || manifest_tuples=""
  fi
  if [[ -f "$verification" ]]; then
    verification_json="$(jq -c '.' "$verification" 2>/dev/null)" || verification_json='[]'
  fi
  if [[ -f "$preserved_actions" ]]; then
    preserved_tuples="$(jq -r --argjson verification "$verification_json" '
      def wrong_only_paths($v):
        ([ $v[]? | select(.status == "WRONG") | .source_finding_path // empty ] | unique) as $wrong
        | [ $v[]? | select(.status != "WRONG") | .source_finding_path // empty ] as $notwrong
        | $wrong
        | map(. as $p | select(($notwrong | index($p)) == null));
      wrong_only_paths($verification) as $wrong_only
      | to_entries[]
      | .value as $action
      | (($action.source_finding_paths // []) | length) as $path_count
      | ([($action.source_finding_paths // [])[] | . as $path | select(($wrong_only | index($path)) != null)] | length) as $wrong_count
      | select(($path_count == 0) or ($wrong_count != $path_count))
      | [.value.cluster_id, .key, .value.type, (.value.issue_number | tostring), .value.body]
      | @tsv
    ' "$preserved_actions" 2>/dev/null)" || preserved_tuples=""
  fi
  tuples="$manifest_tuples"
  if [[ -n "$preserved_tuples" ]]; then
    tuples="${tuples:+$tuples$'\n'}$preserved_tuples"
  fi

  if [[ -z "$tuples" ]]; then
    return 0
  fi

  mkdir -p "$cross_dir" || {
    echo "_filing_cross_link_enact: cannot create cross-link dir: $cross_dir" >&2
    return 0
  }

  # De-duplicate (type, issue_number) across clusters so a comment is posted
  # at most once even when multiple clusters flag the same existing issue.
  local -A seen=()

  local cluster_id action_type issue_number body key sentinel_done sentinel_failed body_file rc
  while IFS=$'\t' read -r cluster_id _ action_type issue_number body; do
    [[ -n "$action_type" && -n "$issue_number" ]] || continue

    # JSON-escaped \n is literal in TSV; restore newlines and the few JSON
    # escape sequences likely to appear in agent-emitted bodies. This is a
    # best-effort restoration — the manifest validator already enforces that
    # body is a non-empty string, so we trust the structure.
    body="${body//\\n/$'\n'}"
    body="${body//\\t/$'\t'}"
    body="${body//\\\"/\"}"
    body="${body//\\\\/\\}"

    key="${action_type}-${issue_number}"
    if [[ -n "${seen[$key]:-}" ]]; then
      continue
    fi
    seen["$key"]=1

    sentinel_done="$cross_dir/$key.done"
    sentinel_failed="$cross_dir/$key.failed"
    if [[ -e "$sentinel_done" || -e "$sentinel_failed" ]]; then
      continue
    fi

    # If the parent cluster failed and has no .url, skip — a comment that
    # references a non-existent new issue is worse than no comment.
    if [[ -n "$cluster_id" && -e "$filed_dir/$cluster_id.failed" && ! -e "$filed_dir/$cluster_id.url" ]]; then
      printf 'cross_link_skipped_parent_failed: cluster=%s key=%s\n' \
        "$cluster_id" "$key" > "$sentinel_failed"
      continue
    fi

    body_file="$cross_dir/$key.body.md"
    printf '%s\n' "$body" > "$body_file" || {
      echo "_filing_cross_link_enact: cannot write body file for $key" >&2
      continue
    }

    rc=0
    case "$action_type" in
      comment)
        if [[ -z "$forge_repo" ]]; then
          echo "_filing_cross_link_enact: FORGE_REPO unset; skipping comment on #$issue_number" >&2
          rc=1
        elif declare -F forge_issue_comment >/dev/null 2>&1; then
          forge_issue_comment "$forge_repo" "$issue_number" "$body_file" \
            >>"$cross_dir/$key.log" 2>&1 || rc=$?
        else
          echo "_filing_cross_link_enact: forge_issue_comment unavailable" >&2
          rc=1
        fi
        ;;
      reopen-suggestion)
        if [[ -z "$forge_repo" ]]; then
          echo "_filing_cross_link_enact: FORGE_REPO unset; skipping reopen-suggestion for #$issue_number" >&2
          rc=1
        elif declare -F forge_issue_create >/dev/null 2>&1; then
          local title="[reopen-candidate] consider re-opening #$issue_number"
          # Prepend a banner so reviewers can see this is a RepoLens-emitted
          # reopen suggestion with the source closed issue called out
          # explicitly in the body.
          local banner_file="$cross_dir/$key.body.banner.md"
          {
            printf '> Generated by RepoLens run %s\n' "${run_id}"
            printf '> Source: closed issue #%s\n\n' "$issue_number"
            cat "$body_file"
            printf '\n\nLabel suggestion: `%s`\n' "$reopen_label"
          } > "$banner_file"
          forge_issue_create "$forge_repo" "$title" "$banner_file" \
            >>"$cross_dir/$key.log" 2>&1 || rc=$?
        else
          echo "_filing_cross_link_enact: forge_issue_create unavailable" >&2
          rc=1
        fi
        ;;
      *)
        echo "_filing_cross_link_enact: unknown action type '$action_type' for #$issue_number" >&2
        rc=1
        ;;
    esac

    if (( rc == 0 )); then
      : > "$sentinel_done"
    else
      printf 'rc=%d action=%s issue=%s\n' "$rc" "$action_type" "$issue_number" \
        > "$sentinel_failed"
      echo "_filing_cross_link_enact: $action_type on #$issue_number failed (rc=$rc), continuing" >&2
    fi
  done <<< "$tuples"

  return 0
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
    mkdir -p "$filed_dir" || {
      echo "dispatch_filing_batch: cannot create filed dir: $filed_dir" >&2
      return 1
    }
    if [[ "${CROSS_LINK_MODE:-off}" != "off" ]]; then
      _filing_cross_link_enact "$run_id" || true
    fi
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

  # Enact cross-link actions after every cluster's filing has settled. The
  # call is best-effort and never affects the overall return value.
  if [[ "${CROSS_LINK_MODE:-off}" != "off" ]]; then
    _filing_cross_link_enact "$run_id" || true
  fi

  printf 'Filed: %d, Verification-failed: %d, Skipped-existing: %d\n' \
    "$filed" "$vfailed" "$skipped_existing"
  return 0
}
