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

# Tests for issue #328: populate also_reported_by[] on the canonical manifest
# record. Pure-function tests only; NO AI models are invoked (the pass under
# test is a deterministic jq/bash transform).
#
# Contract under test (from the issue acceptance criteria):
#   _synthesize_attach_also_reported_by <manifest_path>
#     Deterministic, model-free post-synthesis pass. Groups candidate manifest
#     records into duplicate groups (transitive closure of _dedupe_is_match),
#     picks the canonical via _dedupe_pick_canonical, and on the CANONICAL
#     record sets a sorted also_reported_by[] of { lens, domain, markdown_path }
#     — one entry per NON-canonical contributor. Non-canonical records do NOT
#     gain the field. A group of size 1 produces no also_reported_by. The array
#     is sorted by (domain, lens, markdown_path) and the pass is idempotent.
#     The augmented manifest still passes validate_manifest.
#
# Design notes that shape these tests:
#   - The duplicate group is LOCATION-based (same file, title similarity in the
#     0.60-0.85 band) so the augmented manifest stays BELOW validate_manifest's
#     0.85 near-duplicate-title bar and therefore still validates. A pure-title
#     duplicate group (> 0.85) would be rejected by that pre-existing gate for a
#     reason unrelated to also_reported_by, masking the real assertion.
#   - Thresholds are pinned via DEDUPE_TITLE_SIM_PRIMARY / _SECONDARY so the
#     location branch is stable against future default tuning (#353).
#   - CROSS_LINK_MODE=off (the default) requires empty cross_link_actions[];
#     fixtures honor that so validate_manifest passes for the right reason.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
SYNTH_LIB="$SCRIPT_DIR/lib/synthesize.sh"

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

# assert_eq <desc> <expected> <actual> — exact string equality.
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

# assert_rc <desc> <expected_rc> <actual_rc>
assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" -eq "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected rc $expected, got $actual"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source libraries. core first; synthesize defines the pass under test and
# the title-similarity primitives. dedupe.sh is lazy-loaded BY the pass itself,
# so we deliberately do NOT pre-source it — this exercises the lazy-source
# wiring. -----------------------------------------------------------------------
# shellcheck source=/dev/null
source "$CORE_LIB"
# shellcheck source=/dev/null
source "$SYNTH_LIB"

TOTAL=$((TOTAL + 1))
if declare -F _synthesize_attach_also_reported_by >/dev/null 2>&1; then
  pass_with "_synthesize_attach_also_reported_by is defined after sourcing synthesize.sh"
else
  fail_with "_synthesize_attach_also_reported_by is defined after sourcing synthesize.sh" \
    "function not found in lib/synthesize.sh"
  finish
fi

# Pin thresholds (also asserts the dedupe helpers are reachable via lazy source)
# and the cross-link gate so validate_manifest passes for the right reason.
export DEDUPE_TITLE_SIM_PRIMARY=8500
export DEDUPE_TITLE_SIM_SECONDARY=6000
export CROSS_LINK_MODE=off

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# A complete, schema-valid manifest record. Helper keeps fixtures terse while
# satisfying every validate_manifest required field.
make_record() {
  # $1 cluster_id  $2 domain  $3 lens  $4 severity  $5 title
  # $6 primary_location  $7 source_finding_paths (JSON array literal)
  local cid="$1" domain="$2" lens="$3" sev="$4" title="$5" loc="$6" paths="$7"
  jq -nc \
    --arg cid "$cid" --arg domain "$domain" --arg lens "$lens" \
    --arg sev "$sev" --arg title "$title" --arg loc "$loc" \
    --argjson paths "$paths" '
    {
      title: $title, body: ("body for " + $cid), cluster_id: $cid,
      root_cause_category: "rc", domain: $domain, lens: $lens,
      severity: $sev, granularity: "independent",
      source_finding_paths: $paths, primary_location: $loc,
      dedup_against_existing: [], proposed_labels: [], cross_link_actions: []
    }'
}

# ===========================================================================
# Fixture: one LOCATION-based duplicate group of three records (same file,
# titles ~0.71 similar — secondary band) plus one unrelated singleton.
# Record 0 (critical) is the deterministic canonical; 1 and 2 are contributors.
# ===========================================================================
R0="$(make_record c0 security mtls-auth critical \
  "missing mtls client certificate cn validation in handshake" \
  "src/server/mtls.go:88" '["logs/r/lens-outputs/security/mtls-auth.md"]')"
R1="$(make_record c1 networking tls-config high \
  "missing mtls client certificate cn validation in startup" \
  "src/server/mtls.go:90" '["logs/r/lens-outputs/networking/tls-config.md"]')"
R2="$(make_record c2 auth cert-validation high \
  "missing mtls client certificate cn validation in runtime" \
  "src/server/mtls.go:120" '["logs/r/lens-outputs/auth/cert-validation.md"]')"
R3="$(make_record c3 database pool medium \
  "database connection pool exhausted under sustained load" \
  "src/db/pool.go:12" '["logs/r/lens-outputs/database/pool.md"]')"

MANIFEST="$WORKDIR/manifest.json"
jq -nc --argjson r0 "$R0" --argjson r1 "$R1" --argjson r2 "$R2" --argjson r3 "$R3" \
  '[$r0,$r1,$r2,$r3]' > "$MANIFEST"

_synthesize_attach_also_reported_by "$MANIFEST"; RC=$?
assert_rc "pass returns 0 on a valid location-grouped manifest" 0 "$RC"

# --- AC: canonical record (highest severity -> index 0) gains also_reported_by
# listing every NON-canonical contributor with lens, domain, markdown_path. ----
CANON_ARB="$(jq -c '.[0].also_reported_by' "$MANIFEST")"
# Sorted by (domain, lens, markdown_path): auth < networking.
EXPECTED_ARB='[{"lens":"cert-validation","domain":"auth","markdown_path":"logs/r/lens-outputs/auth/cert-validation.md"},{"lens":"tls-config","domain":"networking","markdown_path":"logs/r/lens-outputs/networking/tls-config.md"}]'
assert_eq "canonical also_reported_by lists both contributors, sorted by domain then lens then path" \
  "$EXPECTED_ARB" "$CANON_ARB"

# --- AC: deterministic ordering (sorted). Assert the domain sequence directly. -
DOMAIN_ORDER="$(jq -c '[.[0].also_reported_by[].domain]' "$MANIFEST")"
assert_eq "also_reported_by is ordered by domain (auth before networking)" \
  '["auth","networking"]' "$DOMAIN_ORDER"

# --- AC: each contributor entry has exactly lens, domain, markdown_path. -------
ENTRY_KEYS="$(jq -c '[.[0].also_reported_by[] | (keys | sort)] | unique' "$MANIFEST")"
assert_eq "contributor entries have exactly {domain,lens,markdown_path}" \
  '[["domain","lens","markdown_path"]]' "$ENTRY_KEYS"

# --- AC: NON-canonical records do NOT get also_reported_by. --------------------
HAS_FIELD="$(jq -c '[.[] | has("also_reported_by")]' "$MANIFEST")"
assert_eq "only the canonical record carries also_reported_by" \
  '[true,false,false,false]' "$HAS_FIELD"

# --- AC: a group of size 1 produces no also_reported_by (the singleton). -------
SINGLETON_HAS="$(jq -c '.[3] | has("also_reported_by")' "$MANIFEST")"
assert_eq "singleton (group of size 1) has no also_reported_by" "false" "$SINGLETON_HAS"

# --- AC: validate_manifest still passes on the augmented manifest. -------------
validate_manifest "$MANIFEST" 2>/dev/null; RC=$?
assert_rc "validate_manifest passes on the augmented manifest" 0 "$RC"

# --- AC: idempotent — re-running yields a byte-identical manifest. -------------
BEFORE="$(jq -S . "$MANIFEST")"
_synthesize_attach_also_reported_by "$MANIFEST"; RC=$?
assert_rc "second pass returns 0" 0 "$RC"
AFTER="$(jq -S . "$MANIFEST")"
TOTAL=$((TOTAL + 1))
if [[ "$BEFORE" == "$AFTER" ]]; then
  pass_with "pass is idempotent (re-run is byte-identical)"
else
  fail_with "pass is idempotent (re-run is byte-identical)" \
    "manifest changed on the second run"
fi

# ===========================================================================
# markdown_path determinism: a contributor with several source_finding_paths
# must contribute its FIRST path.
# ===========================================================================
M2="$WORKDIR/manifest-multi.json"
C0="$(make_record d0 security s-lens critical \
  "missing mtls client certificate cn validation in handshake" \
  "src/server/mtls.go:5" '["logs/r/lens-outputs/security/first.md"]')"
C1="$(make_record d1 auth a-lens high \
  "missing mtls client certificate cn validation in startup" \
  "src/server/mtls.go:9" '["logs/r/lens-outputs/auth/first.md","logs/r/lens-outputs/auth/second.md"]')"
jq -nc --argjson c0 "$C0" --argjson c1 "$C1" '[$c0,$c1]' > "$M2"
_synthesize_attach_also_reported_by "$M2"; RC=$?
assert_rc "two-record location group: pass returns 0" 0 "$RC"
MD_PATH="$(jq -r '.[0].also_reported_by[0].markdown_path' "$M2")"
assert_eq "markdown_path uses the contributor's FIRST source_finding_paths entry" \
  "logs/r/lens-outputs/auth/first.md" "$MD_PATH"
ARB_LEN="$(jq -c '.[0].also_reported_by | length' "$M2")"
assert_eq "two-record group yields exactly one contributor entry" "1" "$ARB_LEN"
NONCANON_HAS="$(jq -c '.[1] | has("also_reported_by")' "$M2")"
assert_eq "two-record group: non-canonical has no also_reported_by" "false" "$NONCANON_HAS"

# ===========================================================================
# No duplicates: records that share neither title nor location must NOT group,
# so none gain also_reported_by.
# ===========================================================================
M3="$WORKDIR/manifest-distinct.json"
D0="$(make_record e0 security alpha high \
  "sql injection in user search endpoint" \
  "src/search.go:10" '["logs/r/lens-outputs/security/alpha.md"]')"
D1="$(make_record e1 perf beta high \
  "n plus one query in dashboard loader" \
  "src/dash.go:20" '["logs/r/lens-outputs/perf/beta.md"]')"
jq -nc --argjson d0 "$D0" --argjson d1 "$D1" '[$d0,$d1]' > "$M3"
_synthesize_attach_also_reported_by "$M3"; RC=$?
assert_rc "distinct records: pass returns 0" 0 "$RC"
ANY_FIELD="$(jq -c 'any(.[]; has("also_reported_by"))' "$M3")"
assert_eq "distinct records gain no also_reported_by" "false" "$ANY_FIELD"

# ===========================================================================
# Degenerate inputs: empty array and a single record are no-op successes.
# ===========================================================================
M_EMPTY="$WORKDIR/empty.json"
printf '[]\n' > "$M_EMPTY"
_synthesize_attach_also_reported_by "$M_EMPTY"; RC=$?
assert_rc "empty array: pass returns 0 (no-op)" 0 "$RC"
assert_eq "empty array stays empty" "[]" "$(jq -c . "$M_EMPTY")"

M_ONE="$WORKDIR/one.json"
jq -nc --argjson r0 "$R0" '[$r0]' > "$M_ONE"
_synthesize_attach_also_reported_by "$M_ONE"; RC=$?
assert_rc "single record: pass returns 0 (no-op)" 0 "$RC"
ONE_HAS="$(jq -c '.[0] | has("also_reported_by")' "$M_ONE")"
assert_eq "single record gains no also_reported_by" "false" "$ONE_HAS"

# ===========================================================================
# Idempotency guard: a pre-existing also_reported_by is stripped/recomputed, not
# appended to. Seed the canonical with a bogus entry; the pass must overwrite it.
# ===========================================================================
M_SEED="$WORKDIR/seed.json"
jq -c '.[0].also_reported_by = [{"lens":"stale","domain":"stale","markdown_path":"stale.md"}]' "$MANIFEST" > "$M_SEED"
_synthesize_attach_also_reported_by "$M_SEED"; RC=$?
assert_rc "pre-seeded manifest: pass returns 0" 0 "$RC"
SEED_ARB="$(jq -c '.[0].also_reported_by' "$M_SEED")"
assert_eq "pre-existing also_reported_by is overwritten (not appended)" \
  "$EXPECTED_ARB" "$SEED_ARB"

# ===========================================================================
# Missing path argument is a usage error (rc != 0), not a crash.
# ===========================================================================
_synthesize_attach_also_reported_by "" 2>/dev/null; RC=$?
TOTAL=$((TOTAL + 1))
if [[ "$RC" -ne 0 ]]; then
  pass_with "missing manifest path returns non-zero"
else
  fail_with "missing manifest path returns non-zero" "expected non-zero, got 0"
fi

finish
