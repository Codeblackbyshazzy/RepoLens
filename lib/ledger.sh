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

# RepoLens — evidence-ledger / finding-registry helpers.
#
# This module is sourceable; it defines functions only and has no top-level
# side effects. It depends on no globals — every function works purely from
# its arguments — so it is safe to source alone under `set -uo pipefail`.
#
# The finding registry (`logs/<run-id>/final/findings.jsonl`, schema in
# docs/finding-registry-schema.md) needs a STABLE `id` so the same finding
# earns the same id across runs and across both source paths (manifest
# clusters and `--local` markdown frontmatter). This module owns that id.
#
# NOTE: this is a DIFFERENT identity from the verifier's per-run
# `_round_digest_finding_id` (lib/rounds.sh): that one is SHA-1 over
# lens/domain/round/suspect-files for matching verification.json entries.
# The registry id below is title-derived (content-stable, not suspect-file
# derived) and carries an `fnd-` prefix to keep the two visually distinct.

# _ledger_normalize_title <title>
#   Normalizes a finding title for stable hashing: lowercases, strips an
#   optional leading "[severity]" prefix (only when the bracketed word is a
#   real severity), collapses non-alphanumeric runs to single spaces, trims.
#
#   Prefers the shared `_synthesize_normalize_title` (lib/synthesize.sh) when
#   it is already sourced, so the two stay in lockstep; otherwise falls back to
#   a self-contained replica so lib/ledger.sh works when sourced on its own.
_ledger_normalize_title() {
  if declare -F _synthesize_normalize_title >/dev/null 2>&1; then
    _synthesize_normalize_title "$1"
    return
  fi

  # Self-contained replica of lib/synthesize.sh::_synthesize_normalize_title.
  # The severity word set (critical|high|medium|low) is inlined to match
  # lib/core.sh::severity_normalize without taking a hard dependency on it.
  local title="${1:-}"
  if [[ "$title" =~ ^\[([A-Za-z]+)\][[:space:]]*(.*)$ ]]; then
    case "${BASH_REMATCH[1],,}" in
      critical|high|medium|low) title="${BASH_REMATCH[2]}" ;;
    esac
  fi
  title="${title,,}"
  local out="" ch i len="${#title}"
  for (( i = 0; i < len; i++ )); do
    ch="${title:i:1}"
    case "$ch" in
      [a-z0-9]) out+="$ch" ;;
      *) out+=' ' ;;
    esac
  done
  out="${out## }"
  out="${out%% }"
  while [[ "$out" == *"  "* ]]; do
    out="${out//  / }"
  done
  printf '%s' "$out"
}

# _ledger_sha256_hex
#   Reads stdin and prints its lowercase SHA-256 as 64 hex chars. Mirrors the
#   repo's hash cascade (lib/forge.sh::_forge_label_set_hash): sha256sum, then
#   shasum -a 256. No cksum fallback here — the finding id must be a real,
#   collision-resistant content hash, and both tools are present on this host.
_ledger_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# finding_id <domain> <lens> <title> [primary_location]
#   Prints a stable, content-derived finding id of the form `fnd-<12 hex>`.
#
#   The title argument is normalized internally (see _ledger_normalize_title),
#   so casing, a leading "[severity]" prefix, and punctuation differences do
#   not change the id. The canonical pre-image is the four fields joined by the
#   ASCII Unit Separator (US, 0x1F), SHA-256 hashed, truncated to 12 hex chars.
#
#   `primary_location` is optional; when omitted it hashes as an empty trailing
#   field (stable). Deterministic: identical args always yield the same id.
finding_id() {
  local domain="${1:-}" lens="${2:-}" title="${3:-}" location="${4:-}"
  local sep=$'\037' norm hex

  norm="$(_ledger_normalize_title "$title")"
  hex="$(printf '%s' "${domain}${sep}${lens}${sep}${norm}${sep}${location}" \
    | _ledger_sha256_hex)"

  printf 'fnd-%s\n' "${hex:0:12}"
}
