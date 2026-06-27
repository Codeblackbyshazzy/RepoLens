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

# Tests for issue #335: mark non-canonical duplicates status=duplicate and link
# to the canonical record's id. Pure-function tests only; NO AI models are
# invoked (the pass under test is a deterministic jq/bash transform).
#
# Contract under test (from the issue acceptance criteria):
#   _synthesize_mark_duplicates <manifest_path>
#     Deterministic, model-free post-synthesis pass. Groups candidate manifest
#     records into duplicate groups (transitive closure of _dedupe_is_match),
#     picks the canonical via _dedupe_pick_canonical, and on every NON-canonical
#     member of a group of size >= 2 sets:
#         status:       "duplicate"
#         duplicate_of: "<canonical record's cluster_id>"
#     The canonical record is left status-UNSET (no "canonical" value — that is
#     not in the ledger status enum) and gains no duplicate_of. Singletons are
#     untouched. The pass owns duplicate_of (always strip+recompute) and owns
#     status only when it equals "duplicate" (strip+recompute), preserving any
#     other status verbatim. Idempotent; the augmented manifest still passes
#     validate_manifest.
#
# Design notes that shape these tests (same trap as #328):
#   - The duplicate group is LOCATION-based (same file, title similarity in the
#     0.60-0.85 band) so the augmented manifest stays BELOW validate_manifest's
#     0.85 near-duplicate-title bar and therefore still validates. A pure-title
#     duplicate group (> 0.85) would be rejected by that pre-existing gate for a
#     reason unrelated to this pass, masking the real assertion.
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
if declare -F _synthesize_mark_duplicates >/dev/null 2>&1; then
  pass_with "_synthesize_mark_duplicates is defined after sourcing synthesize.sh"
else
  fail_with "_synthesize_mark_duplicates is defined after sourcing synthesize.sh" \
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
# Record 0 (critical) is the deterministic canonical; 1 and 2 are non-canonical.
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

_synthesize_mark_duplicates "$MANIFEST"; RC=$?
assert_rc "pass returns 0 on a valid location-grouped manifest" 0 "$RC"

# --- AC: each NON-canonical record gets status="duplicate". --------------------
R1_STATUS="$(jq -r '.[1].status // "<unset>"' "$MANIFEST")"
R2_STATUS="$(jq -r '.[2].status // "<unset>"' "$MANIFEST")"
assert_eq "non-canonical record 1 has status=duplicate" "duplicate" "$R1_STATUS"
assert_eq "non-canonical record 2 has status=duplicate" "duplicate" "$R2_STATUS"

# --- AC: each NON-canonical record's duplicate_of points at the canonical id. --
R1_DOF="$(jq -r '.[1].duplicate_of // "<unset>"' "$MANIFEST")"
R2_DOF="$(jq -r '.[2].duplicate_of // "<unset>"' "$MANIFEST")"
# Canonical is the highest-severity record (index 0, critical) -> cluster_id c0.
assert_eq "non-canonical record 1 duplicate_of points at the canonical cluster_id" "c0" "$R1_DOF"
assert_eq "non-canonical record 2 duplicate_of points at the canonical cluster_id" "c0" "$R2_DOF"

# --- AC: duplicate_of equals the id selected by _dedupe_pick_canonical. --------
# The pass lazy-sources dedupe.sh inside a command-substitution subshell, so the
# helpers are not visible here; source it explicitly for this direct-call check
# (the pass's own lazy-source wiring was already exercised by the calls above).
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/dedupe.sh"
SUBARR="$(jq -c '[ (.[0] + {__rl_idx:0}), (.[1] + {__rl_idx:1}), (.[2] + {__rl_idx:2}) ]' "$MANIFEST")"
CANON_IDX="$(_dedupe_pick_canonical "$SUBARR" __rl_idx)"
CANON_ID="$(jq -r --argjson k "$CANON_IDX" '.[$k].cluster_id' "$MANIFEST")"
assert_eq "duplicate_of equals the _dedupe_pick_canonical-selected canonical cluster_id" \
  "$CANON_ID" "$R1_DOF"

# --- AC: the CANONICAL record is left status-UNSET and gains no duplicate_of. ---
CANON_HAS_STATUS="$(jq -c '.[0] | has("status")' "$MANIFEST")"
CANON_HAS_DOF="$(jq -c '.[0] | has("duplicate_of")' "$MANIFEST")"
assert_eq "canonical record has no status (clearly distinguishable, no \"canonical\" value)" \
  "false" "$CANON_HAS_STATUS"
assert_eq "canonical record has no duplicate_of" "false" "$CANON_HAS_DOF"

# --- AC: only the non-canonical group members carry the marks. -----------------
STATUS_MAP="$(jq -c '[.[] | has("status")]' "$MANIFEST")"
DOF_MAP="$(jq -c '[.[] | has("duplicate_of")]' "$MANIFEST")"
assert_eq "exactly the two non-canonical members carry status" \
  '[false,true,true,false]' "$STATUS_MAP"
assert_eq "exactly the two non-canonical members carry duplicate_of" \
  '[false,true,true,false]' "$DOF_MAP"

# --- AC: a group of size 1 (the singleton) is untouched. -----------------------
SINGLE_HAS_STATUS="$(jq -c '.[3] | has("status")' "$MANIFEST")"
SINGLE_HAS_DOF="$(jq -c '.[3] | has("duplicate_of")' "$MANIFEST")"
assert_eq "singleton (group of size 1) gains no status" "false" "$SINGLE_HAS_STATUS"
assert_eq "singleton (group of size 1) gains no duplicate_of" "false" "$SINGLE_HAS_DOF"

# --- AC: validate_manifest still passes on the marked manifest. ----------------
validate_manifest "$MANIFEST" 2>/dev/null; RC=$?
assert_rc "validate_manifest passes on the marked manifest" 0 "$RC"

# --- AC: idempotent — re-running yields a byte-identical manifest. -------------
BEFORE="$(jq -S . "$MANIFEST")"
_synthesize_mark_duplicates "$MANIFEST"; RC=$?
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
# Two-record location group: exactly the single non-canonical record is marked.
# ===========================================================================
M2="$WORKDIR/manifest-two.json"
C0="$(make_record d0 security s-lens critical \
  "missing mtls client certificate cn validation in handshake" \
  "src/server/mtls.go:5" '["logs/r/lens-outputs/security/first.md"]')"
C1="$(make_record d1 auth a-lens high \
  "missing mtls client certificate cn validation in startup" \
  "src/server/mtls.go:9" '["logs/r/lens-outputs/auth/first.md"]')"
jq -nc --argjson c0 "$C0" --argjson c1 "$C1" '[$c0,$c1]' > "$M2"
_synthesize_mark_duplicates "$M2"; RC=$?
assert_rc "two-record location group: pass returns 0" 0 "$RC"
assert_eq "two-record group: canonical has no status" "false" "$(jq -c '.[0] | has("status")' "$M2")"
assert_eq "two-record group: non-canonical has status=duplicate" \
  "duplicate" "$(jq -r '.[1].status' "$M2")"
assert_eq "two-record group: non-canonical duplicate_of points at canonical d0" \
  "d0" "$(jq -r '.[1].duplicate_of' "$M2")"

# ===========================================================================
# No duplicates: records that share neither title nor location must NOT group,
# so none gain status/duplicate_of.
# ===========================================================================
M3="$WORKDIR/manifest-distinct.json"
E0="$(make_record e0 security alpha high \
  "sql injection in user search endpoint" \
  "src/search.go:10" '["logs/r/lens-outputs/security/alpha.md"]')"
E1="$(make_record e1 perf beta high \
  "n plus one query in dashboard loader" \
  "src/dash.go:20" '["logs/r/lens-outputs/perf/beta.md"]')"
jq -nc --argjson e0 "$E0" --argjson e1 "$E1" '[$e0,$e1]' > "$M3"
_synthesize_mark_duplicates "$M3"; RC=$?
assert_rc "distinct records: pass returns 0" 0 "$RC"
assert_eq "distinct records gain no status" "false" "$(jq -c 'any(.[]; has("status"))' "$M3")"
assert_eq "distinct records gain no duplicate_of" "false" "$(jq -c 'any(.[]; has("duplicate_of"))' "$M3")"

# ===========================================================================
# Idempotency / stale-mark clearing: a record that WAS a duplicate in a prior
# run but no longer matches must have its pass-owned marks cleared. Seed the
# singleton with a stale status="duplicate" + duplicate_of; the pass must strip
# both (the singleton matches nobody).
# ===========================================================================
M_STALE="$WORKDIR/manifest-stale.json"
# Rebuild from the source records and seed stale duplicate marks on a genuine
# group member (R2) and on the singleton (R3, which matches nobody).
jq -nc --argjson r0 "$R0" --argjson r1 "$R1" --argjson r2 "$R2" --argjson r3 "$R3" \
  '[$r0,$r1,($r2 + {status:"duplicate", duplicate_of:"stale"}),
    ($r3 + {status:"duplicate", duplicate_of:"stale"})]' > "$M_STALE"
_synthesize_mark_duplicates "$M_STALE"; RC=$?
assert_rc "stale-seeded manifest: pass returns 0" 0 "$RC"
# R3 (singleton) had a stale duplicate mark — it must be cleared.
assert_eq "stale status=duplicate on a now-singleton record is cleared" \
  "false" "$(jq -c '.[3] | has("status")' "$M_STALE")"
assert_eq "stale duplicate_of on a now-singleton record is cleared" \
  "false" "$(jq -c '.[3] | has("duplicate_of")' "$M_STALE")"
# R2 is a genuine non-canonical member — its mark is recomputed (still set).
assert_eq "genuine non-canonical record is re-marked status=duplicate" \
  "duplicate" "$(jq -r '.[2].status' "$M_STALE")"
assert_eq "genuine non-canonical record duplicate_of recomputed to canonical c0" \
  "c0" "$(jq -r '.[2].duplicate_of' "$M_STALE")"

# ===========================================================================
# Non-dedupe status is preserved verbatim: the pass owns status ONLY when it
# equals the managed value "duplicate". A foreign status survives untouched
# (only its duplicate_of, which the pass always owns, is stripped).
# ===========================================================================
M_KEEP="$WORKDIR/manifest-keep-status.json"
jq -nc --argjson r3 "$R3" '[ $r3 + {status:"needs-validation", duplicate_of:"bogus"} ]' > "$M_KEEP"
_synthesize_mark_duplicates "$M_KEEP"; RC=$?
assert_rc "foreign-status manifest: pass returns 0" 0 "$RC"
assert_eq "non-\"duplicate\" status (needs-validation) is preserved verbatim" \
  "needs-validation" "$(jq -r '.[0].status' "$M_KEEP")"
assert_eq "duplicate_of is always stripped on a singleton even with a foreign status" \
  "false" "$(jq -c '.[0] | has("duplicate_of")' "$M_KEEP")"

# ===========================================================================
# Degenerate inputs: empty array and a single record are no-op successes.
# ===========================================================================
M_EMPTY="$WORKDIR/empty.json"
printf '[]\n' > "$M_EMPTY"
_synthesize_mark_duplicates "$M_EMPTY"; RC=$?
assert_rc "empty array: pass returns 0 (no-op)" 0 "$RC"
assert_eq "empty array stays empty" "[]" "$(jq -c . "$M_EMPTY")"

M_ONE="$WORKDIR/one.json"
jq -nc --argjson r0 "$R0" '[$r0]' > "$M_ONE"
_synthesize_mark_duplicates "$M_ONE"; RC=$?
assert_rc "single record: pass returns 0 (no-op)" 0 "$RC"
assert_eq "single record gains no status" "false" "$(jq -c '.[0] | has("status")' "$M_ONE")"
assert_eq "single record gains no duplicate_of" "false" "$(jq -c '.[0] | has("duplicate_of")' "$M_ONE")"

# ===========================================================================
# Missing path argument is a usage error (rc != 0), not a crash.
# ===========================================================================
_synthesize_mark_duplicates "" 2>/dev/null; RC=$?
TOTAL=$((TOTAL + 1))
if [[ "$RC" -ne 0 ]]; then
  pass_with "missing manifest path returns non-zero"
else
  fail_with "missing manifest path returns non-zero" "expected non-zero, got 0"
fi

finish
