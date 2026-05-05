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

# RepoLens — Forge provider detection and wrapper dispatch

set -uo pipefail

# detect_forge_provider <remote_url>
#   Prints exactly one of: gh | tea | fj | unknown
#
#   Detection rules:
#     host == github.com         -> gh
#     host == codeberg.org       -> fj
#     host matches *gitea*       -> tea   (case-insensitive substring)
#     anything else / malformed  -> unknown
#
#   Supported URL forms:
#     https://[user@]host[:port]/owner/repo[.git]
#     git@host:owner/repo[.git]                         (scp-like SSH)
#     ssh://[user@]host[:port]/owner/repo[.git]
#
#   Exit code is always 0 — callers parse stdout.
detect_forge_provider() {
  local url="${1:-}"
  local host
  host="$(_forge_remote_host "$url")"

  if [[ -z "$host" ]]; then
    printf 'unknown\n'
    return 0
  fi

  # Hosts are case-insensitive per RFC 3986 §3.2.2.
  local host_lower="${host,,}"

  # Exact-match rules come first so a host like "gitea.github.com" (hypothetical)
  # would not incorrectly classify as tea.
  case "$host_lower" in
    github.com)    printf 'gh\n' ;;
    codeberg.org)  printf 'fj\n' ;;
    *gitea*)       printf 'tea\n' ;;
    *)             printf 'unknown\n' ;;
  esac
  return 0
}

# detect_forge_host <remote_url>
#   Prints the host/base URL to pass to `fj -H`.
#
#   Codeberg and SSH remotes use the bare host. HTTPS self-hosted Forgejo
#   remotes preserve scheme, port, and any base path before owner/repo.
#   Plain HTTP remotes are rejected by returning an empty binding so callers do
#   not pass authenticated fj traffic over an insecure transport.
#   Exit code is always 0; malformed or empty input prints an empty string.
detect_forge_host() {
  local url="${1:-}"
  if [[ -z "$url" ]]; then
    printf '\n'
    return 0
  fi

  local host
  host="$(_forge_remote_host "$url")"
  if [[ -z "$host" ]]; then
    printf '\n'
    return 0
  fi

  if [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/]+)(/.*)?$ ]]; then
    local scheme="${BASH_REMATCH[1],,}"
    local authority="${BASH_REMATCH[2]}"
    local path="${BASH_REMATCH[3]:-}"

    if [[ "$scheme" == "http" ]]; then
      printf '\n'
      return 0
    fi

    if [[ "$scheme" == "https" ]]; then
      if [[ "$host" == "codeberg.org" ]]; then
        printf 'codeberg.org\n'
        return 0
      fi

      authority="${authority##*@}"
      local host_part="${authority%%:*}"
      local port_part=""
      if [[ "$authority" == *:* ]]; then
        port_part=":${authority#*:}"
      fi

      local base_path
      base_path="$(_forge_http_base_path "$path")"
      printf '%s://%s%s%s\n' "$scheme" "${host_part,,}" "$port_part" "$base_path"
      return 0
    fi

    if [[ "$scheme" == "ssh" ]]; then
      printf '%s\n' "$host"
      return 0
    fi

    printf '\n'
    return 0
  fi

  printf '%s\n' "$host"
  return 0
}

_forge_remote_host() {
  local url="${1:-}"
  local host=""

  if [[ -z "$url" ]]; then
    printf '\n'
    return 0
  fi

  # Form 1: scp-like SSH — user@host:path (no scheme, colon separates host from path).
  if [[ "$url" =~ ^[^@/:]+@([^:/]+): ]]; then
    host="${BASH_REMATCH[1]}"
  # Form 2: URL with scheme — scheme://[user@]host[:port]/path
  elif [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+)(/|$) ]]; then
    local authority="${BASH_REMATCH[1]}"
    authority="${authority##*@}"
    host="${authority%%:*}"
  fi

  printf '%s\n' "${host,,}"
  return 0
}

_forge_http_base_path() {
  local path="${1:-}"
  path="${path%%\?*}"
  path="${path%%#*}"
  while [[ "$path" == */ ]]; do
    path="${path%/}"
  done
  path="${path#/}"

  if [[ -z "$path" ]]; then
    printf ''
    return 0
  fi

  local -a parts=()
  IFS='/' read -r -a parts <<< "$path"
  local count="${#parts[@]}"
  if (( count <= 2 )); then
    printf ''
    return 0
  fi

  local base="" i
  for ((i = 0; i < count - 2; i++)); do
    [[ -n "${parts[$i]}" ]] || continue
    base+="/${parts[$i]}"
  done
  printf '%s' "$base"
  return 0
}

# require_forge_cli <provider>
#   Verifies the forge CLI binary for <provider> is on PATH.
#   On success: returns 0 silently.
#   On failure: calls die() with a provider-specific install hint (exit 1).
#
#   Valid providers: gh | tea | fj
#   Any other value dies with an "unknown provider" message to guard against
#   caller typos.
#
#   Depends on die() from lib/core.sh — sourcing forge.sh without core.sh
#   means callers must define die themselves (the companion
#   detect_forge_provider has no such dependency).
require_forge_cli() {
  local provider="${1:-}"
  case "$provider" in
    gh)
      command -v gh >/dev/null 2>&1 \
        || die "gh not found — install from https://cli.github.com"
      ;;
    tea)
      command -v tea >/dev/null 2>&1 \
        || die "tea not found — install from https://gitea.com/gitea/tea"
      ;;
    fj)
      command -v fj >/dev/null 2>&1 \
        || die "fj not found — install from https://codeberg.org/forgejo-contrib/forgejo-cli"
      ;;
    *)
      die "require_forge_cli: unknown provider '$provider' (expected gh|tea|fj)"
      ;;
  esac
}

# forge_auth_status
#   Verify the user is authenticated against the current forge. Prints
#   nothing on success; dies on failure. Provider dispatch reads
#   $FORGE_PROVIDER (resolved by repolens.sh before any forge call).
#
#   gh  → `gh auth status` — exit 0 ok, non-zero triggers die with the
#         exact README-troubleshooting message.
#   tea → `tea login list` — exit 0 ok, non-zero triggers die with a
#         Gitea-specific setup hint.
#   fj  → `fj -H <host> whoami` — exit 0 ok, non-zero triggers die with
#         a Forgejo-specific setup hint.
#
#   Callers in repolens.sh keep their outer `if ! $LOCAL_MODE` gate —
#   this wrapper is provider-aware but not mode-aware.
#
#   Depends on die() from lib/core.sh.
forge_auth_status() {
  case "${FORGE_PROVIDER:-}" in
    gh)
      gh auth status >/dev/null 2>&1 \
        || die "gh is not authenticated. Run 'gh auth login'."
      ;;
    tea)
      tea login list >/dev/null 2>&1 \
        || die "tea is not authenticated. Run 'tea login add'."
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_auth_status: fj backend requires FORGE_HOST"
      fj -H "$FORGE_HOST" whoami >/dev/null 2>&1 \
        || die "fj is not authenticated. Run 'fj -H $FORGE_HOST auth login' or 'fj -H $FORGE_HOST auth add-key <user>'."
      ;;
    *)
      die "forge_auth_status: unknown provider '${FORGE_PROVIDER:-}' (expected gh|tea|fj)"
      ;;
  esac
}

# forge_label_create <label> <color> <owner/repo>
#   Create or update (upsert) a label on the target repository.
#   Best-effort by design: non-zero exit from the underlying CLI is
#   swallowed (matches the pre-refactor inline `|| true`) so a labels
#   permission error never halts a run.
#
#   gh  → `gh label create <label> --color <color> --force -R <owner/repo>`
#         with stderr suppressed and exit ignored.
#   tea → `tea labels create --name <label> --color <color> ...`
#         bound to $FORGE_PROJECT_PATH/$FORGE_REMOTE_NAME or $FORGE_TEA_LOGIN.
#   fj  → `fj -H <host> repo labels <owner/repo> create <label> <color>`
#         with stderr suppressed and exit ignored.
#
#   All three args are required; any missing arg is a caller bug and
#   dies loudly rather than pass garbage to the forge CLI.
#
#   Depends on die() from lib/core.sh.
forge_label_create() {
  local label="${1:-}" color="${2:-}" repo="${3:-}"
  [[ -n "$label" && -n "$color" && -n "$repo" ]] \
    || die "forge_label_create: missing argument (label='$label' color='$color' repo='$repo')"

  case "${FORGE_PROVIDER:-}" in
    gh)
      gh label create "$label" --color "$color" --force -R "$repo" 2>/dev/null || true
      ;;
    tea)
      local -a tea_target_flags=()
      if [[ -n "${FORGE_PROJECT_PATH:-}" ]]; then
        tea_target_flags=(--repo "$FORGE_PROJECT_PATH" --remote "${FORGE_REMOTE_NAME:-origin}")
      elif [[ -n "${FORGE_TEA_LOGIN:-}" ]]; then
        tea_target_flags=(--repo "$repo" --login "$FORGE_TEA_LOGIN")
      else
        die "forge_label_create: tea backend requires FORGE_PROJECT_PATH or FORGE_TEA_LOGIN for target binding"
      fi
      tea labels create --name "$label" --color "$color" "${tea_target_flags[@]}" 2>/dev/null || true
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_label_create: fj backend requires FORGE_HOST"
      fj -H "$FORGE_HOST" repo labels "$repo" create "$label" "$color" 2>/dev/null || true
      ;;
    *)
      die "forge_label_create: unknown provider '${FORGE_PROVIDER:-}' (expected gh|tea|fj)"
      ;;
  esac
}

# forge_issue_list_count <owner/repo> <label>
#   Counts open issues carrying <label> on the target repository.
#   Prints the integer count on stdout and returns 0 on success.
#   On forge CLI or JSON parsing failure, prints nothing to stdout, emits
#   a warning diagnostic, and returns 1 so callers can distinguish "unknown"
#   from "legitimately zero".
#
#   gh  -> `gh issue list -R <owner/repo> --label <label> --state open
#          --limit 1000 --json number`, counted via jq.
#   tea -> `tea issues list ... --labels <label> --state open --limit 1000
#          --output json`, bound to $FORGE_PROJECT_PATH/$FORGE_REMOTE_NAME or
#          $FORGE_TEA_LOGIN, counted via jq.
#   fj  -> `fj -H <host> --style minimal issue search --repo <owner/repo>
#          --labels <label> --state open`, parsed from the leading count line.
#
#   Both args are required; missing args are caller bugs and die loudly.
#
#   Depends on die() from lib/core.sh and jq being available on PATH.
forge_issue_list_count() {
  local repo="${1:-}" label="${2:-}"
  [[ -n "$repo" && -n "$label" ]] \
    || die "forge_issue_list_count: missing argument (repo='$repo' label='$label')"

  case "${FORGE_PROVIDER:-}" in
    gh)
      local gh_err gh_out gh_rc
      gh_err="$(mktemp 2>/dev/null)" || gh_err=""
      if [[ -n "$gh_err" ]]; then
        gh_out="$(gh issue list -R "$repo" --label "$label" --state open \
          --limit 1000 --json number 2>"$gh_err")"
        gh_rc=$?
      else
        gh_out="$(gh issue list -R "$repo" --label "$label" --state open \
          --limit 1000 --json number 2>/dev/null)"
        gh_rc=$?
      fi
      if [[ "$gh_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$gh_err" && -s "$gh_err" ]]; then
          first_err="$(head -n1 "$gh_err" 2>/dev/null || true)"
        fi
        [[ -n "$gh_err" ]] && rm -f "$gh_err"
        _forge_warn "forge_issue_list_count: gh failed for repo=$repo label=$label rc=$gh_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$gh_err" ]] && rm -f "$gh_err"

      local n
      if ! n="$(printf '%s' "$gh_out" | jq 'length' 2>/dev/null)"; then
        _forge_warn "forge_issue_list_count: jq failed to parse gh output for repo=$repo label=$label"
        return 1
      fi
      if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        _forge_warn "forge_issue_list_count: unexpected non-integer from jq for repo=$repo label=$label: '$n'"
        return 1
      fi
      printf '%s\n' "$n"
      return 0
      ;;
    tea)
      local -a tea_target_flags=()
      if [[ -n "${FORGE_PROJECT_PATH:-}" ]]; then
        tea_target_flags=(--repo "$FORGE_PROJECT_PATH" --remote "${FORGE_REMOTE_NAME:-origin}")
      elif [[ -n "${FORGE_TEA_LOGIN:-}" ]]; then
        tea_target_flags=(--repo "$repo" --login "$FORGE_TEA_LOGIN")
      else
        die "forge_issue_list_count: tea backend requires FORGE_PROJECT_PATH or FORGE_TEA_LOGIN for target binding"
      fi

      local tea_err tea_out tea_rc
      tea_err="$(mktemp 2>/dev/null)" || tea_err=""
      if [[ -n "$tea_err" ]]; then
        tea_out="$(tea issues list "${tea_target_flags[@]}" --labels "$label" --state open \
          --limit 1000 --output json 2>"$tea_err")"
        tea_rc=$?
      else
        tea_out="$(tea issues list "${tea_target_flags[@]}" --labels "$label" --state open \
          --limit 1000 --output json 2>/dev/null)"
        tea_rc=$?
      fi
      if [[ "$tea_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$tea_err" && -s "$tea_err" ]]; then
          first_err="$(head -n1 "$tea_err" 2>/dev/null || true)"
        fi
        [[ -n "$tea_err" ]] && rm -f "$tea_err"
        _forge_warn "forge_issue_list_count: tea failed for repo=$repo label=$label rc=$tea_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$tea_err" ]] && rm -f "$tea_err"

      local n
      if ! n="$(printf '%s' "$tea_out" | jq 'length' 2>/dev/null)"; then
        _forge_warn "forge_issue_list_count: jq failed to parse tea output for repo=$repo label=$label"
        return 1
      fi
      if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        _forge_warn "forge_issue_list_count: unexpected non-integer from jq for repo=$repo label=$label: '$n'"
        return 1
      fi
      printf '%s\n' "$n"
      return 0
      ;;
    fj)
      [[ -n "${FORGE_HOST:-}" ]] \
        || die "forge_issue_list_count: fj backend requires FORGE_HOST"

      local fj_err fj_out fj_rc
      fj_err="$(mktemp 2>/dev/null)" || fj_err=""
      if [[ -n "$fj_err" ]]; then
        fj_out="$(fj -H "$FORGE_HOST" --style minimal issue search \
          --repo "$repo" --labels "$label" --state open 2>"$fj_err")"
        fj_rc=$?
      else
        fj_out="$(fj -H "$FORGE_HOST" --style minimal issue search \
          --repo "$repo" --labels "$label" --state open 2>/dev/null)"
        fj_rc=$?
      fi
      if [[ "$fj_rc" -ne 0 ]]; then
        local first_err=""
        if [[ -n "$fj_err" && -s "$fj_err" ]]; then
          first_err="$(head -n1 "$fj_err" 2>/dev/null || true)"
        fi
        [[ -n "$fj_err" ]] && rm -f "$fj_err"
        _forge_warn "forge_issue_list_count: fj failed for repo=$repo label=$label rc=$fj_rc err=${first_err:-<empty>}"
        return 1
      fi
      [[ -n "$fj_err" ]] && rm -f "$fj_err"

      local first_line
      first_line="$(printf '%s\n' "$fj_out" | sed -n '1p')"
      if [[ "$first_line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+issues?[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      fi

      _forge_warn "forge_issue_list_count: could not parse fj output for repo=$repo label=$label first_line='${first_line:-<empty>}'"
      return 1
      ;;
    *)
      die "forge_issue_list_count: unknown provider '${FORGE_PROVIDER:-}' (expected gh|tea|fj)"
      ;;
  esac
}

# Internal: delegates to log_warn when logging.sh is sourced, otherwise
# falls back to stderr so forge wrappers remain usable in library-level tests.
_forge_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$*"
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}
