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

# RepoLens — DONE streak detection

if ! declare -F severity_normalize >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"
fi

# Strip ANSI escape sequences from stdin.
# Uses a bash variable for the ESC byte instead of \x1b hex escapes in sed,
# because BSD sed (macOS) does not support \x1b — only GNU sed does.
strip_ansi() {
  local esc=$'\x1b'
  sed -E "s/${esc}\[[0-9;]*[a-zA-Z]//g; s/${esc}\([0-9;]*[a-zA-Z]//g; s/${esc}\]8;[^\\\\]*\\\\//g"
}

# Strip non-alphanumeric (keep _), uppercase.
normalize_word() {
  local word="${1:-}"
  printf "%s" "$word" | tr -cd '[:alnum:]_' | tr '[:lower:]' '[:upper:]'
}

# Extract first word from file. Returns "" if file empty/missing.
# Strips ANSI escape codes before extraction so colored agent output is handled.
first_word() {
  local file="$1"
  [[ -s "$file" ]] || { echo ""; return 0; }
  strip_ansi < "$file" | awk 'NF {for (i = 1; i <= NF; i++) { print $i; exit }}'
}

# Extract last word from file. Returns "" if file empty/missing.
# Strips ANSI escape codes before extraction so colored agent output is handled.
last_word() {
  local file="$1"
  [[ -s "$file" ]] || { echo ""; return 0; }
  strip_ansi < "$file" | awk '{for (i = 1; i <= NF; i++) { last = $i }} END { if (last) print last }'
}

# Returns 0 if first OR last normalized word is "DONE", 1 otherwise.
check_done() {
  local file="$1"
  local first_norm last_norm
  first_norm="$(normalize_word "$(first_word "$file")")"
  last_norm="$(normalize_word "$(last_word "$file")")"
  [[ "$first_norm" == "DONE" || "$last_norm" == "DONE" ]]
}

# count_issues_in_output <file>
#   Counts GitHub issue URLs in agent output (printed by issue creation on success).
#   Best-effort fallback — agents may not echo the full URL. Prefer
#   forge_issue_list_count from lib/forge.sh when querying a forge directly.
#   Returns count on stdout.
count_issues_in_output() {
  local file="$1"
  [[ -s "$file" ]] || { echo 0; return 0; }
  grep -oE 'https://github\.com/[^/]+/[^/]+/issues/[0-9]+' "$file" 2>/dev/null | wc -l
}

# count_dry_run_issues <dir>
#   Counts .md files in a directory (maxdepth 1, no subdirectories).
#   Returns count on stdout. Returns 0 if directory is empty or missing.
count_dry_run_issues() {
  local dir="$1" file severity count
  [[ -d "$dir" ]] || { echo 0; return 0; }
  if [[ -z "${REPOLENS_MIN_SEVERITY:-}" ]]; then
    find "$dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l
    return 0
  fi

  count=0
  while IFS= read -r file; do
    severity="$(
      awk '
        NR == 1 && $0 == "---" { in_fm = 1; next }
        in_fm && $0 == "---" { exit }
        in_fm && $0 ~ /^[[:space:]]*severity[[:space:]]*:/ {
          sub(/^[[:space:]]*severity[[:space:]]*:[[:space:]]*/, "")
          gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "")
          print
          exit
        }
      ' "$file"
    )"
    severity="$(severity_normalize "$severity")"
    if [[ -n "$severity" ]] && severity_meets_min "$severity" "$REPOLENS_MIN_SEVERITY"; then
      count=$((count + 1))
    fi
  done < <(find "$dir" -maxdepth 1 -name '*.md' -type f -print 2>/dev/null)
  echo "$count"
}

# Rate-limit / quota / auth-failure signatures emitted by agent CLIs
# (claude, codex, spark, opencode). Case-insensitive ERE patterns.
# Extend this list when new agent error strings surface. These patterns are
# intentionally context-aware because agent transcripts can also contain
# ordinary command output, including issue titles about rate limiting.
_REPOLENS_RATE_LIMIT_PATTERNS=(
  "you('|’)?ve hit your usage limit"
  "you('|’)?ve hit your[[:space:]]+limit[[:space:]]*·[[:space:]]*resets[[:space:]]"
  "usage limit (exceeded|reached|hit)"
  "(error|fatal|failed|failure|exception|http|api|request|provider|claude|codex|opencode|spark)[^[:alnum:]_].*rate[- ]?limit(ed|ing|s)?"
  "rate[- ]?limit(ed|ing|s)?([^[:alnum:]_]|$).*(exceeded|reached|hit|retry-after|try again|until)"
  "http[ /]*(1\\.[01][[:space:]]*)?429"
  "rate[[:space:]-]*limit[[:space:]-]*exceeded"
  "secondary rate[- ]?limit"
  "ratelimiterror"
  "try again (at|in)"
  "quota exceeded"
  "401 unauthorized"
  "403 forbidden"
)

# detect_agent_rate_limit <output_file>
#   Returns 0 if any known rate-limit / quota / auth-failure signature is
#   found in the file, 1 otherwise. Matching is case-insensitive and
#   applied to ANSI-stripped output (so colored terminal output still
#   matches).
#
#   On match, prints "PATTERN|SNIPPET" to stdout where PATTERN is the
#   signature that matched and SNIPPET is the first 200 characters of
#   the matching line. Callers can split on the first "|" to extract
#   both fields for logging.
#
#   Intentionally avoids matching the orchestrator's own `gh` 401 errors
#   because `run_agent`'s stdout/stderr is captured separately — only the
#   agent subprocess writes to <output_file>.
detect_agent_rate_limit() {
  local file="$1"
  [[ -s "$file" ]] || return 1

  local stripped pat line
  stripped="$(strip_ansi < "$file" 2>/dev/null | grep -viE '^[[:space:]]*[0-9]+[[:space:]]+(OPEN|CLOSED)[[:space:]]' || true)"
  [[ -n "$stripped" ]] || return 1

  for pat in "${_REPOLENS_RATE_LIMIT_PATTERNS[@]}"; do
    line="$(printf '%s\n' "$stripped" | grep -iE -m1 "$pat" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
      # Trim leading whitespace for a cleaner snippet
      line="${line#"${line%%[![:space:]]*}"}"
      printf '%s|%s\n' "$pat" "${line:0:200}"
      return 0
    fi
  done
  return 1
}

# classify_agent_iteration <output_file> <agent_rc>
#   Classifies a failed agent iteration into the persistent classes that should
#   abort the whole run, the existing rate-limit class, or unknown. Successful
#   iterations are always unknown so findings that quote these phrases do not
#   trip global abort handling.
classify_agent_iteration() {
  local file="$1" agent_rc="${2:-0}"
  [[ "$agent_rc" -ne 0 && -s "$file" ]] || { printf '%s\n' "unknown"; return 0; }

  local stripped line
  stripped="$(strip_ansi < "$file" 2>/dev/null || true)"
  [[ -n "$stripped" ]] || { printf '%s\n' "unknown"; return 0; }

  line="$(printf '%s\n' "$stripped" | grep -iE -m1 'not logged in|please run /login' 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    printf '%s\n' "auth-expired"
    return 0
  fi

  line="$(printf '%s\n' "$stripped" | grep -iE -m1 'issue with the selected model|selected model.*(does not exist|not available|may not exist)|model.*may not exist.*not available' 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    printf '%s\n' "model-unavailable"
    return 0
  fi

  line="$(printf '%s\n' "$stripped" | grep -iE -m1 'exceeded usd budget|error_max_budget_usd|max[-_ ]budget[-_ ]usd' 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    printf '%s\n' "budget-exhausted"
    return 0
  fi

  if detect_agent_rate_limit "$file" >/dev/null; then
    printf '%s\n' "rate-limited"
  else
    printf '%s\n' "unknown"
  fi
}

# _handle_agent_rate_limit_in_phase <phase> <output_file>
#   Shared non-lens phase policy for failed agent invocations. Returns 0 only
#   when <output_file> contains a known upstream rate-limit/quota/auth failure.
_handle_agent_rate_limit_in_phase() {
  local phase="${1:-agent-phase}" output_file="${2:-}"
  local rl_hit rl_sig rl_snip stop_reason

  [[ -n "$output_file" && -s "$output_file" ]] || return 1
  rl_hit="$(detect_agent_rate_limit "$output_file" || true)"
  [[ -n "$rl_hit" ]] || return 1

  rl_sig="${rl_hit%%|*}"
  rl_snip="${rl_hit#*|}"
  stop_reason="rate-limited-${phase}"

  if declare -F log_warn >/dev/null 2>&1 && [[ -n "${_REPOLENS_LOG_FILE+x}" ]]; then
    log_warn "[$phase] Agent rate-limited / quota exceeded. Aborting run. Matched: $rl_sig. Snippet: $rl_snip"
  else
    printf '%s\n' "[$phase] Agent rate-limited / quota exceeded. Aborting run. Matched: $rl_sig. Snippet: $rl_snip" >&2
  fi

  if [[ -n "${LOG_BASE:-}" ]]; then
    mkdir -p "$LOG_BASE" 2>/dev/null || true
    : > "$LOG_BASE/.rate-limit-abort"
  fi

  if [[ -n "${SUMMARY_FILE:-}" && -f "${SUMMARY_FILE:-}" ]] && declare -F set_stop_reason >/dev/null 2>&1; then
    set_stop_reason "$SUMMARY_FILE" "$stop_reason"
  fi

  return 0
}

handle_agent_rate_limit_in_phase() {
  _handle_agent_rate_limit_in_phase "$@"
}

# parse_rate_limit_resume_epoch <output_file>
#   Prints a Unix epoch when a known rate-limit resume time can be parsed from
#   ANSI-stripped agent output. Prints nothing when no usable resume time is
#   present. This helper intentionally does not decide whether the output is a
#   rate-limit failure; callers must keep that check separate.
parse_rate_limit_resume_epoch() {
  local file="$1"
  [[ -s "$file" ]] || { echo ""; return 0; }

  local stripped now_epoch seconds line fragment lower candidate epoch time_part zone resets_re
  stripped="$(strip_ansi < "$file" 2>/dev/null)"
  [[ -n "$stripped" ]] || { echo ""; return 0; }

  now_epoch="$(date +%s)"

  seconds="$(printf '%s\n' "$stripped" | sed -nE 's/.*[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*([0-9]+).*/\1/p' | head -n 1)"
  if [[ "$seconds" =~ ^[0-9]+$ ]]; then
    printf '%s\n' $((now_epoch + seconds))
    return 0
  fi

  line="$(printf '%s\n' "$stripped" | grep -iE -m1 'retry[[:space:]]+after[[:space:]]+[0-9]+[[:space:]]+seconds?' 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower" =~ retry[[:space:]]+after[[:space:]]+([0-9]+)[[:space:]]+seconds?([^[:alpha:]]|$) ]]; then
      seconds=$((10#${BASH_REMATCH[1]}))
      printf '%s\n' $((now_epoch + seconds))
      return 0
    fi
  fi

  line="$(printf '%s\n' "$stripped" | grep -iE -m1 'try again in[[:space:]]+[0-9]' 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    fragment="$(printf '%s\n' "$line" | sed -E 's/.*[Tt][Rr][Yy][[:space:]]+[Aa][Gg][Aa][Ii][Nn][[:space:]]+[Ii][Nn][[:space:]]+//')"
    lower="$(printf '%s' "$fragment" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lower" =~ ^([0-9]+)[[:space:]]*h([[:space:]]*([0-9]+)[[:space:]]*m)?([^[:alpha:]]|$) ]]; then
      seconds=$((10#${BASH_REMATCH[1]} * 3600))
      if [[ -n "${BASH_REMATCH[3]:-}" ]]; then
        seconds=$((seconds + 10#${BASH_REMATCH[3]} * 60))
      fi
      printf '%s\n' $((now_epoch + seconds))
      return 0
    fi

    if [[ "$lower" =~ ^([0-9]+)[[:space:]]*(hours?|hrs?|hr)([[:space:]]+([0-9]+)[[:space:]]*(minutes?|mins?|min))?([^[:alpha:]]|$) ]]; then
      seconds=$((10#${BASH_REMATCH[1]} * 3600))
      if [[ -n "${BASH_REMATCH[4]:-}" ]]; then
        seconds=$((seconds + 10#${BASH_REMATCH[4]} * 60))
      fi
      printf '%s\n' $((now_epoch + seconds))
      return 0
    fi

    if [[ "$lower" =~ ^([0-9]+)[[:space:]]*(minutes?|mins?|min|m)([^[:alpha:]]|$) ]]; then
      seconds=$((10#${BASH_REMATCH[1]} * 60))
      printf '%s\n' $((now_epoch + seconds))
      return 0
    fi

    if [[ "$lower" =~ ^([0-9]+)[[:space:]]*(seconds?|secs?|sec|s)([^[:alpha:]]|$) ]]; then
      seconds=$((10#${BASH_REMATCH[1]}))
      printf '%s\n' $((now_epoch + seconds))
      return 0
    fi
  fi

  line="$(printf '%s\n' "$stripped" | grep -iE -m1 'resets[[:space:]]+[0-9]' 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    fragment="$(printf '%s\n' "$line" | sed -E 's/.*[Rr][Ee][Ss][Ee][Tt][Ss][[:space:]]+//')"
    fragment="${fragment#"${fragment%%[![:space:]]*}"}"
    fragment="${fragment%"${fragment##*[![:space:]]}"}"

    resets_re='^(([0-9]{1,2}:[0-9]{2})([[:space:]]*[AaPp][Mm])?|([0-9]{1,2})([[:space:]]*[AaPp][Mm]))[[:space:]]*(\(([^)]+)\))?'
    if [[ "$fragment" =~ $resets_re ]]; then
      time_part="${BASH_REMATCH[1]}"
      zone="${BASH_REMATCH[7]:-}"
      time_part="${time_part#"${time_part%%[![:space:]]*}"}"
      time_part="${time_part%"${time_part##*[![:space:]]}"}"
      zone="${zone#"${zone%%[![:space:]]*}"}"
      zone="${zone%"${zone##*[![:space:]]}"}"

      epoch=""
      if [[ -n "$zone" ]]; then
        if [[ "$zone" =~ ^[A-Za-z_]+(/[A-Za-z_+-]+)+$ || "$zone" =~ ^[A-Za-z]{2,5}$ ]]; then
          epoch="$(TZ="$zone" date -d "$time_part" +%s 2>/dev/null || true)"
        fi
        if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
          epoch="$(date -d "$time_part $zone" +%s 2>/dev/null || true)"
        fi
      else
        epoch="$(date -d "$time_part" +%s 2>/dev/null || true)"
      fi

      if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        if [[ "$epoch" -le "$now_epoch" ]]; then
          epoch=$((epoch + 86400))
        fi
        printf '%s\n' "$epoch"
        return 0
      fi
    fi
  fi

  candidate="$(printf '%s\n' "$stripped" | sed -nE 's/.*[Tt][Rr][Yy][[:space:]]+[Aa][Gg][Aa][Ii][Nn][[:space:]]+[Aa][Tt][[:space:]]+(.+)/\1/p' | head -n 1)"
  [[ -n "$candidate" ]] || { echo ""; return 0; }

  candidate="${candidate#"${candidate%%[![:space:]]*}"}"
  candidate="${candidate%"${candidate##*[![:space:]]}"}"
  while [[ "$candidate" == *. || "$candidate" == *";" ]]; do
    candidate="${candidate%?}"
  done
  candidate="${candidate%"${candidate##*[![:space:]]}"}"
  candidate="$(printf '%s' "$candidate" | sed -E 's/([0-9]+)([sS][tT]|[nN][dD]|[rR][dD]|[tT][hH])([^[:alpha:]]|$)/\1\3/g')"

  epoch="$(date -d "$candidate" +%s 2>/dev/null || true)"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    if [[ "$candidate" =~ ^[0-9]{1,2}:[0-9]{2}([[:space:]]*[AaPp][Mm])?([[:space:]]+[[:alpha:]]{2,5})?$ && "$epoch" -le "$now_epoch" ]]; then
      epoch=$((epoch + 86400))
    fi
    printf '%s\n' "$epoch"
    return 0
  fi

  echo ""
  return 0
}
