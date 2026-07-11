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

# Tests for issue #338: lib/ledger.sh — build_finding_registry orchestrator.
# The four source-specific builders already exist and are unit-tested in
# isolation; this orchestrator is the glue that selects the right source(s),
# concatenates + de-duplicates by id, validates, and ATOMICALLY promotes
# final/findings.jsonl + final/findings.csv under the resolved log base.
# Pure jq/bash file-assembly; NO AI models are invoked.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"

# The exact 12-column CSV header build_findings_csv emits, asserted byte-for-byte
# (kept in lockstep with lib/ledger.sh::build_findings_csv). Issue #385 appended
# `complexity` at the END, keeping every pre-existing column index stable.
CSV_HEADER='id,title,severity,type,domain,lens,status,primary_location,confidence,duplicate_group,markdown_path,complexity'

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-ledger-build-registry"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit, got 0"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect file $path"
  fi
}

# assert_jq <desc> <jq-filter> <file-or-line> [via_stdin]
#   Passes when `jq -e <filter>` exits 0. When the 4th arg is "stdin" the third
#   arg is treated as a JSON string fed on stdin; otherwise it is a file path.
assert_jq() {
  local desc="$1" filter="$2" subject="$3" mode="${4:-file}"
  TOTAL=$((TOTAL + 1))
  local rc
  if [[ "$mode" == "stdin" ]]; then
    jq -e "$filter" <<<"$subject" >/dev/null 2>&1
    rc=$?
  else
    jq -e "$filter" "$subject" >/dev/null 2>&1
    rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq filter failed (rc=$rc): $filter"
  fi
}

# assert_no_litter <desc> <dir>
#   Atomic-promotion guard. After a build, the final dir must hold ONLY the
#   promoted artifacts — no half-written candidate and no intermediate
#   scaffolding. Catches any leftover `*.tmp*` candidate (the AC's "no .tmp left
#   behind") AND any hidden intermediate (a dotfile such as a `.dedup`/`.fr-*`
#   merge buffer). The promoted outputs (findings.jsonl/.csv) and a pre-placed
#   manifest.json match neither pattern, so a clean build leaves nothing here.
assert_no_litter() {
  local desc="$1" dir="$2"
  TOTAL=$((TOTAL + 1))
  local litter
  litter="$(find "$dir" -type f \( -name '*.tmp*' -o -name '.*' \) 2>/dev/null)"
  if [[ -z "$litter" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "intermediate artifacts survived: $(echo "$litter" | tr '\n' ' ')"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Source lib/ledger.sh ALONE (must stay self-contained) -----------------
# build_finding_registry must orchestrate the sibling builders without pulling
# in lib/synthesize.sh / lib/core.sh; sourcing ledger on its own proves the
# LOG_BASE resolver and all four called builders are self-contained.
TOTAL=$((TOTAL + 1))
if [[ -f "$LEDGER_LIB" ]]; then
  pass_with "lib/ledger.sh exists"
else
  fail_with "lib/ledger.sh exists" "missing: $LEDGER_LIB"
  finish
fi

# shellcheck source=/dev/null
source "$LEDGER_LIB"

TOTAL=$((TOTAL + 1))
if declare -F build_finding_registry >/dev/null 2>&1; then
  pass_with "build_finding_registry is defined after sourcing ledger alone"
else
  fail_with "build_finding_registry is defined after sourcing ledger alone" \
    "function not found — implementation pending (TDD red phase)"
  finish
fi

# Shared fixture builders -----------------------------------------------------

# write_manifest <path> — a 2-cluster manifest exercising both source branches.
#   cluster X: code/input-validation (collides with the local md in scenario c)
#   cluster Y: deployment/tls          (manifest-only id)
write_manifest() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'JSON'
[
  {
    "cluster_id": "missing-validation::upload-handler",
    "title": "[high] Validate upload filenames before writing files",
    "severity": "High",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": [
      "logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"
    ],
    "granularity": "independent",
    "verification_status": "verified",
    "body": "## Summary\nUploads are not sanitized."
  },
  {
    "cluster_id": "weak-crypto::tls-config",
    "title": "Weak TLS ciphers enabled on the edge",
    "severity": "critical",
    "domain": "deployment",
    "lens": "tls",
    "root_cause_category": "weak-crypto",
    "source_finding_paths": [
      "logs/run-1/rounds/round-1/lens-outputs/deployment/tls.md"
    ],
    "granularity": "independent",
    "verification_status": "wrong",
    "body": "## Summary\nLegacy ciphers."
  }
]
JSON
}

# write_local_tree <dir> — a 2-file --local md tree.
#   collide md: code/input-validation, SAME title as manifest cluster X -> same id
#   fresh md:   code/secrets, a local-only id
write_local_tree() {
  local dir="$1"
  mkdir -p "$dir/code/input-validation" "$dir/code/secrets"
  cat > "$dir/code/input-validation/001-validate-uploads.md" <<'EOF'
---
title: "[high] Validate upload filenames before writing files"
severity: high
domain: code
lens: input-validation
---

## Summary
Uploads are not validated.
EOF
  cat > "$dir/code/secrets/002-leaked-secret.md" <<'EOF'
---
title: "[medium] Hardcoded API secret in committed config"
severity: medium
domain: code
lens: secrets
---

## Summary
A secret was committed.
EOF
}

# ===========================================================================
# (a) manifest-only -> jsonl + csv produced under the resolved log base.
# ===========================================================================
echo "=== (a) manifest-only source ==="

LB_A="$TMPDIR/lb-a"
write_manifest "$LB_A/final/manifest.json"

LOG_BASE="$LB_A" build_finding_registry "run-a"
rc_a=$?
assert_success "manifest-only: build returns exit 0" "$rc_a"

jsonl_a="$LB_A/final/findings.jsonl"
csv_a="$LB_A/final/findings.csv"
assert_file_exists "manifest-only: findings.jsonl is promoted" "$jsonl_a"
assert_file_exists "manifest-only: findings.csv is promoted" "$csv_a"

# One JSONL line per manifest cluster (2 clusters -> 2 lines).
lines_a="$(wc -l < "$jsonl_a" | tr -d ' ')"
assert_eq "manifest-only: 2 manifest clusters -> 2 jsonl lines" "2" "$lines_a"

# CSV header is the exact 12-col contract; data rows == jsonl lines.
header_a="$(head -n1 "$csv_a")"
assert_eq "manifest-only: csv first line is the 12-col header" "$CSV_HEADER" "$header_a"
csv_rows_a=$(( $(wc -l < "$csv_a" | tr -d ' ') - 1 ))
assert_eq "manifest-only: csv data rows == jsonl line count" "2" "$csv_rows_a"

# The promoted registry validates against the schema.
validate_findings_jsonl "$jsonl_a" >/dev/null 2>&1
assert_success "manifest-only: promoted registry passes validate_findings_jsonl" "$?"

# Atomic promotion: nothing but the promoted artifacts (+ the source manifest)
# survives under final/.
assert_no_litter "manifest-only: no temp/intermediate litter after build" "$LB_A"

# Determinism: a second build of the same source is byte-identical (jsonl + csv).
cp "$jsonl_a" "$TMPDIR/a-jsonl.first"
cp "$csv_a" "$TMPDIR/a-csv.first"
LOG_BASE="$LB_A" build_finding_registry "run-a" >/dev/null 2>&1
TOTAL=$((TOTAL + 1))
if diff -q "$TMPDIR/a-jsonl.first" "$jsonl_a" >/dev/null 2>&1 \
   && diff -q "$TMPDIR/a-csv.first" "$csv_a" >/dev/null 2>&1; then
  pass_with "manifest-only: two builds of the same source are byte-identical"
else
  fail_with "manifest-only: two builds of the same source are byte-identical" \
    "rebuilt jsonl/csv differ from the first build"
fi

# ===========================================================================
# (b) local-md-only -> exercise BOTH ways the local dir is supplied:
#     (b1) as the 2nd positional arg; (b2) via the OUTPUT_DIR global.
# ===========================================================================
echo "=== (b1) local-md-only source (param) ==="

LB_B="$TMPDIR/lb-b"
local_dir_b="$TMPDIR/output-b"
write_local_tree "$local_dir_b"

LOG_BASE="$LB_B" build_finding_registry "run-b" "$local_dir_b"
rc_b=$?
assert_success "local-only (param): build returns exit 0" "$rc_b"

jsonl_b="$LB_B/final/findings.jsonl"
csv_b="$LB_B/final/findings.csv"
assert_file_exists "local-only (param): findings.jsonl is promoted" "$jsonl_b"
assert_file_exists "local-only (param): findings.csv is promoted" "$csv_b"

lines_b="$(wc -l < "$jsonl_b" | tr -d ' ')"
assert_eq "local-only (param): 2 md files -> 2 jsonl lines" "2" "$lines_b"

records_b="$(jq -s '.' "$jsonl_b")"
# The whole point of the local source: markdown_path is populated on every row.
assert_jq "local-only (param): markdown_path is a non-empty string on every row" \
  'all(.[]; .markdown_path | type == "string" and length > 0)' "$records_b" stdin

header_b="$(head -n1 "$csv_b")"
assert_eq "local-only (param): csv first line is the 12-col header" "$CSV_HEADER" "$header_b"
assert_no_litter "local-only (param): no temp/intermediate litter after build" "$LB_B"

echo "=== (b2) local-md-only source (OUTPUT_DIR global) ==="

LB_B2="$TMPDIR/lb-b2"
# Supply the dir through the OUTPUT_DIR global with NO 2nd arg. The subshell
# scopes OUTPUT_DIR/LOG_BASE so they don't leak into later scenarios.
(
  # shellcheck disable=SC2030,SC2031  # LOG_BASE is intentionally subshell-scoped
  export LOG_BASE="$LB_B2"
  # shellcheck disable=SC2034  # read by build_finding_registry via the OUTPUT_DIR global
  OUTPUT_DIR="$local_dir_b"
  build_finding_registry "run-b2"
)
rc_b2=$?
assert_success "local-only (OUTPUT_DIR): build returns exit 0" "$rc_b2"

jsonl_b2="$LB_B2/final/findings.jsonl"
assert_file_exists "local-only (OUTPUT_DIR): findings.jsonl is promoted" "$jsonl_b2"
assert_file_exists "local-only (OUTPUT_DIR): findings.csv is promoted" "$LB_B2/final/findings.csv"
lines_b2="$(wc -l < "$jsonl_b2" | tr -d ' ')"
assert_eq "local-only (OUTPUT_DIR): 2 md files -> 2 jsonl lines" "2" "$lines_b2"

# ===========================================================================
# (c) both sources -> identical-id duplicates collapsed (keep one line per id).
# ===========================================================================
echo "=== (c) both sources, identical-id duplicates collapsed ==="

LB_C="$TMPDIR/lb-c"
write_manifest "$LB_C/final/manifest.json"
local_dir_c="$TMPDIR/output-c"
write_local_tree "$local_dir_c"

# The manifest's code/input-validation cluster and the local
# code/input-validation md share the SAME title -> the SAME finding_id.
dup_id="$(finding_id "code" "input-validation" "[high] Validate upload filenames before writing files")"
# Sanity: the collision id is well-formed (otherwise the dedup assertion below
# would be vacuous if dup_id were empty/garbage).
TOTAL=$((TOTAL + 1))
if [[ "$dup_id" =~ ^fnd-[0-9a-f]{12}$ ]]; then
  pass_with "both: crafted collision id has fnd-<12 hex> shape"
else
  fail_with "both: crafted collision id has fnd-<12 hex> shape" "got '$dup_id'"
fi

LOG_BASE="$LB_C" build_finding_registry "run-c" "$local_dir_c"
rc_c=$?
assert_success "both: build returns exit 0" "$rc_c"

jsonl_c="$LB_C/final/findings.jsonl"
assert_file_exists "both: findings.jsonl is promoted" "$jsonl_c"
records_c="$(jq -s '.' "$jsonl_c")"

# manifest contributes {dup_id, tls-id}; local contributes {dup_id, secrets-id};
# after collapsing the shared dup_id the registry holds exactly 3 distinct lines.
lines_c="$(wc -l < "$jsonl_c" | tr -d ' ')"
assert_eq "both: shared id collapsed -> 3 distinct registry lines" "3" "$lines_c"

# No id appears more than once across the merged registry.
assert_jq "both: every id in the merged registry is unique" \
  '([.[].id] | length) == ([.[].id] | unique | length)' "$records_c" stdin

# The colliding id survives exactly once (not zero, not twice).
assert_eq "both: the colliding id appears exactly once" \
  "1" "$(jq --arg id "$dup_id" '[.[] | select(.id == $id)] | length' <<<"$records_c")"

# Both branches actually ran: the manifest-only tls id AND the local-only
# secrets id are both present alongside the shared id.
tls_id="$(finding_id "deployment" "tls" "Weak TLS ciphers enabled on the edge")"
secrets_id="$(finding_id "code" "secrets" "[medium] Hardcoded API secret in committed config")"
assert_eq "both: manifest-only (tls) id is present -> manifest branch ran" \
  "1" "$(jq --arg id "$tls_id" '[.[] | select(.id == $id)] | length' <<<"$records_c")"
assert_eq "both: local-only (secrets) id is present -> local branch ran" \
  "1" "$(jq --arg id "$secrets_id" '[.[] | select(.id == $id)] | length' <<<"$records_c")"

# NOTE: which record wins the tie-break for the shared id (manifest-first vs
# local-first) is deliberately NOT asserted — issue #338's AC only mandates that
# identical-id duplicates collapse, not which source's record is kept. Pinning a
# winner here would couple the test to an implementation choice the issue leaves
# open.

assert_no_litter "both: no temp/intermediate litter after build" "$LB_C"

# ===========================================================================
# (d) neither source -> empty jsonl (0 lines) + header-only csv, exit 0.
# ===========================================================================
echo "=== (d) no sources -> canonical-empty registry ==="

LB_D="$TMPDIR/lb-d"   # fresh: no manifest, no local dir
LOG_BASE="$LB_D" build_finding_registry "run-d"
rc_d=$?
assert_success "no-sources: build returns exit 0" "$rc_d"

jsonl_d="$LB_D/final/findings.jsonl"
csv_d="$LB_D/final/findings.csv"
assert_file_exists "no-sources: findings.jsonl is created" "$jsonl_d"
assert_file_exists "no-sources: findings.csv is created" "$csv_d"

lines_d="$(wc -l < "$jsonl_d" | tr -d ' ')"
assert_eq "no-sources: findings.jsonl is 0 lines" "0" "$lines_d"

csv_lines_d="$(wc -l < "$csv_d" | tr -d ' ')"
assert_eq "no-sources: findings.csv is header-only (exactly 1 line)" "1" "$csv_lines_d"
assert_eq "no-sources: the single csv line is the 12-col header" \
  "$CSV_HEADER" "$(head -n1 "$csv_d")"
assert_no_litter "no-sources: no temp/intermediate litter after build" "$LB_D"

# ===========================================================================
# Atomicity under validation failure: a build whose validation step fails must
# NOT promote findings.jsonl (or derive a csv from it) and must return non-zero.
# Shadow the validator in a subshell (the only deterministic, model-free way to
# force the discard path — the real sub-builders only ever emit valid records).
# ===========================================================================
echo "=== validation failure leaves no promoted registry ==="

LB_F="$TMPDIR/lb-f"
write_manifest "$LB_F/final/manifest.json"

(
  # shellcheck disable=SC2030,SC2031  # LOG_BASE is intentionally subshell-scoped
  export LOG_BASE="$LB_F"
  validate_findings_jsonl() { return 1; }   # force the discard-on-failure branch
  build_finding_registry "run-f"
)
rc_f=$?
assert_failure "validation failure: build returns non-zero" "$rc_f"
assert_file_missing "validation failure: findings.jsonl is NOT promoted" \
  "$LB_F/final/findings.jsonl"
assert_file_missing "validation failure: findings.csv is NOT derived" \
  "$LB_F/final/findings.csv"
# Even on the failure path no half-written candidate may linger.
assert_no_litter "validation failure: no temp/intermediate litter left behind" "$LB_F"

# ===========================================================================
# Sub-builder failure paths. The orchestrator threads each of the four sibling
# builders and must discard + clean up when any of them returns non-zero. The
# validation case above covers validate_findings_jsonl; the three below cover
# the remaining builders. Each shadows the real builder in a subshell (the only
# deterministic, model-free way to drive the error branch — the real builders
# emit only valid records) and asserts the OBSERVABLE contract, not internals.
# ===========================================================================
echo "=== sub-builder failure: manifest ingest fails -> nothing promoted ==="

# manifest.json present so the manifest branch runs, then its builder fails.
LB_GM="$TMPDIR/lb-gm"
write_manifest "$LB_GM/final/manifest.json"
(
  # shellcheck disable=SC2030,SC2031  # LOG_BASE is intentionally subshell-scoped
  export LOG_BASE="$LB_GM"
  build_findings_jsonl_from_manifest() { return 1; }   # force the ingest-fail branch
  build_finding_registry "run-gm"
)
rc_gm=$?
assert_failure "manifest-ingest failure: build returns non-zero" "$rc_gm"
assert_file_missing "manifest-ingest failure: findings.jsonl is NOT promoted" \
  "$LB_GM/final/findings.jsonl"
assert_file_missing "manifest-ingest failure: findings.csv is NOT derived" \
  "$LB_GM/final/findings.csv"
assert_no_litter "manifest-ingest failure: no temp/intermediate litter left behind" "$LB_GM"

echo "=== sub-builder failure: local ingest fails -> nothing promoted ==="

# No manifest, only a local dir, so the manifest branch is skipped and the local
# branch runs, then its builder fails. Proves the local failure path also cleans
# up the empty candidate created before either source ran.
LB_GL="$TMPDIR/lb-gl"
local_dir_gl="$TMPDIR/output-gl"
write_local_tree "$local_dir_gl"
(
  # shellcheck disable=SC2030,SC2031  # LOG_BASE is intentionally subshell-scoped
  export LOG_BASE="$LB_GL"
  build_findings_jsonl_from_local() { return 1; }   # force the ingest-fail branch
  build_finding_registry "run-gl" "$local_dir_gl"
)
rc_gl=$?
assert_failure "local-ingest failure: build returns non-zero" "$rc_gl"
assert_file_missing "local-ingest failure: findings.jsonl is NOT promoted" \
  "$LB_GL/final/findings.jsonl"
assert_file_missing "local-ingest failure: findings.csv is NOT derived" \
  "$LB_GL/final/findings.csv"
assert_no_litter "local-ingest failure: no temp/intermediate litter left behind" "$LB_GL"

echo "=== sub-builder failure: csv projection fails -> jsonl stays promoted ==="

# The jsonl is validated and atomically promoted BEFORE the csv is derived, so a
# csv-projection failure is a PARTIAL success: the (valid) findings.jsonl must
# survive for downstream consumers (result_pointer.sh / human_review.sh / triage
# all read it), the build still reports non-zero, and no csv is written. This
# pins the exact ordering the issue mandates ("build csv from the PROMOTED jsonl").
LB_GC="$TMPDIR/lb-gc"
write_manifest "$LB_GC/final/manifest.json"
(
  # shellcheck disable=SC2030,SC2031  # LOG_BASE is intentionally subshell-scoped
  export LOG_BASE="$LB_GC"
  build_findings_csv() { return 1; }   # validation passes; only the csv step fails
  build_finding_registry "run-gc"
)
rc_gc=$?
assert_failure "csv-projection failure: build returns non-zero" "$rc_gc"
assert_file_exists "csv-projection failure: the promoted findings.jsonl survives" \
  "$LB_GC/final/findings.jsonl"
assert_file_missing "csv-projection failure: findings.csv is NOT written" \
  "$LB_GC/final/findings.csv"
# The promoted jsonl that survives must itself be the valid, deduped registry.
validate_findings_jsonl "$LB_GC/final/findings.jsonl" >/dev/null 2>&1
assert_success "csv-projection failure: the surviving jsonl still validates" "$?"
assert_no_litter "csv-projection failure: no temp/intermediate litter left behind" "$LB_GC"

# ===========================================================================
# Argument guard: a missing run_id is a usage error (non-zero, no work done).
# ===========================================================================
echo "=== argument guard ==="

build_finding_registry >/dev/null 2>&1
rc_arg=$?
assert_failure "missing run_id returns non-zero" "$rc_arg"
# The orchestrator documents two distinct exit codes: 2 = usage error (missing/
# empty run_id), 1 = an operational builder/jq/IO/validation failure. Pin the
# usage code so a caller can distinguish a programming error from a runtime one.
assert_eq "missing run_id returns the documented usage exit code (2)" "2" "$rc_arg"

finish
