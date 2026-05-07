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

# RepoLens — Core utilities
# Sourced by lens scripts. Do NOT execute directly.
set -uo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# ---------------------------------------------------------------------------
# Agent validation
# ---------------------------------------------------------------------------

validate_agent() {
  local agent="$1"
  case "$agent" in
    claude|codex|spark|sparc|opencode) ;;
    opencode/*)
      [[ -n "${agent#opencode/}" ]] || die "Invalid agent: $agent (missing model after 'opencode/')."
      ;;
    *) die "Invalid agent: $agent (expected claude, codex, spark/sparc, opencode, or opencode/<model>)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Agent runner
# ---------------------------------------------------------------------------
# Usage: run_agent <agent> <prompt> <project_path>
#
# Executes the given agent inside the target repository directory.
# The work happens in a subshell so the caller's cwd is never affected.

run_agent() {
  local agent="$1"
  local prompt="$2"
  local project_path="$3"
  local timeout_secs="${REPOLENS_AGENT_TIMEOUT:-6000}"

  [[ -d "$project_path" ]] || die "Project path does not exist: $project_path"

  (
    cd "$project_path" || die "Failed to cd into: $project_path"
    export PROJECT_PATH="$PWD"
    # Close stdin so agents that fall back to interactive prompts (auth
    # failure, login wizard) exit quickly instead of blocking on a read
    # that will never deliver input.
    exec </dev/null

    case "$agent" in
      claude)
        timeout "${timeout_secs}s" claude --dangerously-skip-permissions -p "$prompt"
        ;;
      codex)
        timeout "${timeout_secs}s" codex exec --yolo "$prompt"
        ;;
      spark|sparc)
        timeout "${timeout_secs}s" codex exec --yolo -m gpt-5.3-codex-spark -c reasoning_effort="xhigh" "$prompt"
        ;;
      opencode)
        timeout "${timeout_secs}s" opencode run "$prompt"
        ;;
      opencode/*)
        local opencode_model="${agent#opencode/}"
        timeout "${timeout_secs}s" opencode run -m "$opencode_model" "$prompt"
        ;;
      *)
        die "Internal error: unsupported agent '$agent'"
        ;;
    esac
  )
}
