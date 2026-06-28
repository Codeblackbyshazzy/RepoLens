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

# Coverage for the ledger-side finding-TYPE resolution wired by issue #344.
#
# lib/ledger.sh gained three helpers (mirrors of the lib/core.sh pair, following
# the _ledger_severity_normalize "prefer shared, else self-contained replica"
# pattern) and wired the resolved type into both JSONL builders, replacing the
# old hardcoded `type: null`:
#
#   _ledger_finding_type_normalize <value>   -> canonical id or "" (replica of
#                                               lib/core.sh::finding_type_normalize)
#   _ledger_domain_default_finding_type <d>  -> domain back-compat default
#   _ledger_resolve_finding_type <raw> <d>   -> value-based resolver (raw wins,
#                                               else domain default, never empty)
#
# The two existing builder suites (test_ledger_from_local / _from_manifest) only
# assert the maintainability DEFAULT (every fixture uses an unmapped domain and
# no explicit type:), so the interesting branches — an explicit type: winning, a
# short alias being repaired, and a real domain mapping to a NON-default id — are
# unexercised end-to-end. This file fills that gap: it drives the replica helpers
# across their non-default mappings AND runs the real builders on small fixtures
# to prove the wiring emits the resolved type, not just `maintainability`.
#
# Like the sibling ledger suites this sources lib/ledger.sh ALONE for the bulk of
# the cases, which deliberately exercises the SELF-CONTAINED REPLICA path (the
# shared lib/core.sh functions are absent, so the `declare -F` guard falls
# through to the inline copy). A final section additionally sources lib/core.sh
# to lock the "prefer shared" delegation branch. NO real model is ever invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-ledger-resolve-finding-type"
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
  [[ -n "$detail" ]] && printf '    %s\n' "$detail"
  return 0
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

assert_defined() {
  local desc="$1" fn="$2"
  TOTAL=$((TOTAL + 1))
  if declare -F "$fn" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "function '$fn' is not defined"
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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

if [[ ! -f "$LEDGER_LIB" ]]; then
  fail_with "lib/ledger.sh exists" "missing: $LEDGER_LIB"
  finish
fi

# shellcheck source=/dev/null
source "$LEDGER_LIB"

echo "=== helpers + builders are defined after sourcing lib/ledger.sh alone ==="
assert_defined "_ledger_finding_type_normalize defined" "_ledger_finding_type_normalize"
assert_defined "_ledger_domain_default_finding_type defined" "_ledger_domain_default_finding_type"
assert_defined "_ledger_resolve_finding_type defined" "_ledger_resolve_finding_type"
assert_defined "build_findings_jsonl_from_local defined" "build_findings_jsonl_from_local"
assert_defined "build_findings_jsonl_from_manifest defined" "build_findings_jsonl_from_manifest"

# At this point lib/core.sh is NOT sourced, so the helpers below run their
# self-contained replica branch (the production-relevant "sourced alone" path).
echo "=== _ledger_finding_type_normalize: replica branch (core.sh absent) ==="
assert_eq "long id security-vulnerability round-trips" \
  "security-vulnerability" "$(_ledger_finding_type_normalize "security-vulnerability")"
assert_eq "long id reliability-bug round-trips" \
  "reliability-bug" "$(_ledger_finding_type_normalize "reliability-bug")"
assert_eq "long id performance-risk round-trips" \
  "performance-risk" "$(_ledger_finding_type_normalize "performance-risk")"
assert_eq "long id external-dependency round-trips" \
  "external-dependency" "$(_ledger_finding_type_normalize "external-dependency")"
assert_eq "short alias security -> security-vulnerability" \
  "security-vulnerability" "$(_ledger_finding_type_normalize "security")"
assert_eq "short alias perf -> performance-risk" \
  "performance-risk" "$(_ledger_finding_type_normalize "perf")"
assert_eq "short alias correctness -> reliability-bug" \
  "reliability-bug" "$(_ledger_finding_type_normalize "correctness")"
assert_eq "short alias testing -> test-gap" \
  "test-gap" "$(_ledger_finding_type_normalize "testing")"
assert_eq "short alias cve -> external-dependency" \
  "external-dependency" "$(_ledger_finding_type_normalize "cve")"
assert_eq "bracket-wrapped + mixed case [Security] -> security-vulnerability" \
  "security-vulnerability" "$(_ledger_finding_type_normalize "[Security]")"
assert_eq "unrecognized value -> empty (drives the domain fallback)" \
  "" "$(_ledger_finding_type_normalize "not-a-real-type")"
assert_eq "empty value -> empty" \
  "" "$(_ledger_finding_type_normalize "")"
assert_eq "no-arg -> empty (set -u safe)" \
  "" "$(_ledger_finding_type_normalize)"

echo "=== _ledger_domain_default_finding_type: replica branch (core.sh absent) ==="
assert_eq "security -> security-vulnerability" \
  "security-vulnerability" "$(_ledger_domain_default_finding_type "security")"
assert_eq "llm-security -> security-vulnerability" \
  "security-vulnerability" "$(_ledger_domain_default_finding_type "llm-security")"
assert_eq "testing -> test-gap" \
  "test-gap" "$(_ledger_domain_default_finding_type "testing")"
assert_eq "performance -> performance-risk" \
  "performance-risk" "$(_ledger_domain_default_finding_type "performance")"
assert_eq "error-handling -> reliability-bug" \
  "reliability-bug" "$(_ledger_domain_default_finding_type "error-handling")"
assert_eq "concurrency -> reliability-bug" \
  "reliability-bug" "$(_ledger_domain_default_finding_type "concurrency")"
assert_eq "database -> reliability-bug" \
  "reliability-bug" "$(_ledger_domain_default_finding_type "database")"
assert_eq "unmapped real domain (frontend) -> maintainability default" \
  "maintainability" "$(_ledger_domain_default_finding_type "frontend")"
assert_eq "unknown domain -> maintainability default" \
  "maintainability" "$(_ledger_domain_default_finding_type "totally-not-a-domain")"
assert_eq "empty domain -> maintainability (never empty)" \
  "maintainability" "$(_ledger_domain_default_finding_type "")"
assert_eq "no-arg -> maintainability (set -u safe, never empty)" \
  "maintainability" "$(_ledger_domain_default_finding_type)"
# Trim + lowercase tolerance (mirrors finding_type_normalize's input hygiene).
assert_eq "dirty input '  SECURITY ' -> security-vulnerability (trim+lower)" \
  "security-vulnerability" "$(_ledger_domain_default_finding_type "  SECURITY ")"

echo "=== _ledger_resolve_finding_type: value-based resolver (replica branch) ==="
# (a) explicit valid type wins over the domain default.
assert_eq "explicit long type wins over domain (testing would be test-gap)" \
  "security-vulnerability" "$(_ledger_resolve_finding_type "security-vulnerability" "testing")"
# (a') explicit short alias is repaired, and still wins over the domain default.
assert_eq "explicit short alias 'perf' repaired to performance-risk, beats domain" \
  "performance-risk" "$(_ledger_resolve_finding_type "perf" "documentation")"
# (b) explicit INVALID type -> domain fallback.
assert_eq "invalid type falls back to domain default (security)" \
  "security-vulnerability" "$(_ledger_resolve_finding_type "not-a-real-type" "security")"
# (c) missing/empty type -> domain fallback, exercising each non-default arm.
assert_eq "empty type + database domain -> reliability-bug" \
  "reliability-bug" "$(_ledger_resolve_finding_type "" "database")"
assert_eq "empty type + performance domain -> performance-risk" \
  "performance-risk" "$(_ledger_resolve_finding_type "" "performance")"
assert_eq "empty type + testing domain -> test-gap" \
  "test-gap" "$(_ledger_resolve_finding_type "" "testing")"
# (d) empty type + unknown domain -> maintainability.
assert_eq "empty type + unknown domain -> maintainability" \
  "maintainability" "$(_ledger_resolve_finding_type "" "marketing")"
# never empty: both args empty / no args at all.
assert_eq "both empty -> maintainability (never empty)" \
  "maintainability" "$(_ledger_resolve_finding_type "" "")"
assert_eq "no args -> maintainability (set -u safe, never empty)" \
  "maintainability" "$(_ledger_resolve_finding_type)"

# Robustness invariant: across a spread of (type, domain) inputs the resolver is
# ALWAYS one of the six canonical ids and NEVER empty (AC: records always typed).
echo "=== _ledger_resolve_finding_type: never-empty / always-canonical invariant ==="
canon_re='^(security-vulnerability|reliability-bug|performance-risk|maintainability|test-gap|external-dependency)$'
inv_ok=1
for combo in \
  "security-vulnerability|testing" "perf|x" "bogus|security" "|database" \
  "|frontend" "|" "[cve]|" "Reliability|whatever" "tests|security" "|llm-security"; do
  raw="${combo%%|*}"; dom="${combo#*|}"
  got="$(_ledger_resolve_finding_type "$raw" "$dom")"
  if [[ ! "$got" =~ $canon_re ]]; then
    inv_ok=0
    fail_with "resolver invariant broken for ('$raw','$dom')" "got '$got'"
  fi
done
TOTAL=$((TOTAL + 1))
[[ "$inv_ok" -eq 1 ]] && pass_with "resolver output is always a canonical id, never empty (10 combos)"

# ---------------------------------------------------------------------------
# Builder integration — prove the WIRING emits the resolved type (#344), not the
# trivial maintainability default. Each fixture is built into its own output dir
# so the single JSONL line can be read unambiguously.
# ---------------------------------------------------------------------------
echo "=== build_findings_jsonl_from_local: emits resolved (non-default) type ==="

# build_one <subdir> <frontmatter-domain-line> <frontmatter-type-line> -> echoes .type
# Empty domain/type lines are omitted from the frontmatter.
build_local_type() {
  local name="$1" domain_line="$2" type_line="$3"
  local dir="$TMPDIR/$name/output"
  mkdir -p "$dir"
  {
    printf '%s\n' '---'
    printf 'title: "[high] Wiring fixture %s"\n' "$name"
    printf 'severity: high\n'
    [[ -n "$domain_line" ]] && printf 'domain: %s\n' "$domain_line"
    printf 'lens: synthetic\n'
    [[ -n "$type_line" ]] && printf 'type: %s\n' "$type_line"
    printf '%s\n' '---'
    printf '%s\n' 'Body with a decoy type: SHOULD_NOT_WIN.'
  } > "$dir/001-wiring.md"
  local out="$TMPDIR/$name/findings.jsonl"
  build_findings_jsonl_from_local "$dir" "$out" 2>/dev/null
  jq -r '.type' < "$out"
}

# Explicit valid long-form type: wins over a conflicting domain default.
assert_eq "local builder: explicit type: wins (type=reliability-bug, domain=security)" \
  "reliability-bug" "$(build_local_type explicit security reliability-bug)"
# Explicit SHORT alias is repaired through the builder's frontmatter read.
assert_eq "local builder: short-alias type: 'perf' -> performance-risk" \
  "performance-risk" "$(build_local_type alias documentation perf)"
# No explicit type: -> resolved from the mapped domain (NON-default).
assert_eq "local builder: no type:, domain security -> security-vulnerability" \
  "security-vulnerability" "$(build_local_type domsec security "")"
assert_eq "local builder: no type:, domain database -> reliability-bug" \
  "reliability-bug" "$(build_local_type domdb database "")"
# Unmapped domain, no type: -> maintainability default (parity with existing suite).
assert_eq "local builder: no type:, unmapped domain -> maintainability" \
  "maintainability" "$(build_local_type domdefault frontend "")"

echo "=== build_findings_jsonl_from_local: directory-fallback domain drives type ==="
# A type:-less file nested under <domain>/<lens>/ with NO domain: in frontmatter
# must resolve from the directory-derived domain (the #344 "resolve from the
# post-fallback \$domain" requirement), not blindly default to maintainability.
dirfb="$TMPDIR/dirfb/output/security/some-lens"
mkdir -p "$dirfb"
cat > "$dirfb/001-nodomain.md" <<'EOF'
---
title: "[high] No domain in frontmatter, nested under security/"
severity: high
---

## Summary
Directory fallback should supply domain=security.
EOF
out_dirfb="$TMPDIR/dirfb/findings.jsonl"
build_findings_jsonl_from_local "$TMPDIR/dirfb/output" "$out_dirfb" 2>/dev/null
assert_eq "local builder: directory-derived domain (security) drives type when frontmatter omits domain:" \
  "security-vulnerability" "$(jq -r '.type' < "$out_dirfb")"

echo "=== build_findings_jsonl_from_manifest: type resolves from cluster domain ==="
# The manifest carries no finding type: today, so type resolves purely from each
# cluster's domain. Prove a mapped domain yields a NON-default id, an explicit
# (future-proofed) cluster .type is honored, and an unmapped domain defaults.
manifest="$TMPDIR/manifest.json"
cat > "$manifest" <<'EOF'
[
  {"cluster_id":"c1","title":"Cluster in the security domain","severity":"high","domain":"security","lens":"authz","verification_status":"verified","source_finding_paths":["logs/run-1/a.md"]},
  {"cluster_id":"c2","title":"Cluster carrying an explicit short-alias type","severity":"medium","type":"perf","domain":"code","lens":"hotpath","verification_status":"verified","source_finding_paths":["logs/run-1/b.md"]},
  {"cluster_id":"c3","title":"Cluster in an unmapped domain","severity":"low","domain":"frontend","lens":"layout","verification_status":"verified","source_finding_paths":["logs/run-1/c.md"]}
]
EOF
out_manifest="$TMPDIR/manifest-findings.jsonl"
build_findings_jsonl_from_manifest "$manifest" "$out_manifest" 2>/dev/null
mrc=$?
assert_success "manifest builder returns exit 0" "$mrc"
assert_eq "manifest builder: security-domain cluster -> security-vulnerability" \
  "security-vulnerability" \
  "$(jq -r 'select(.title=="Cluster in the security domain") | .type' < "$out_manifest")"
assert_eq "manifest builder: explicit cluster type 'perf' -> performance-risk" \
  "performance-risk" \
  "$(jq -r 'select(.title=="Cluster carrying an explicit short-alias type") | .type' < "$out_manifest")"
assert_eq "manifest builder: unmapped-domain cluster -> maintainability default" \
  "maintainability" \
  "$(jq -r 'select(.title=="Cluster in an unmapped domain") | .type' < "$out_manifest")"
# No registry record may carry a null type after #344 wired the resolver in.
assert_eq "manifest builder: no record has a null type" \
  "0" "$(jq -rs 'map(select(.type == null)) | length' < "$out_manifest")"

# ---------------------------------------------------------------------------
# "Prefer shared lib/core.sh" delegation branch. Once core.sh is sourced the
# `declare -F` guards in the _ledger_* helpers must delegate to the shared
# functions and still yield identical canonical output (the production path —
# repolens.sh sources both). This locks the delegation branch that the
# replica-only sections above cannot reach.
# ---------------------------------------------------------------------------
echo "=== delegation branch: shared lib/core.sh present ==="
if [[ -f "$CORE_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$CORE_LIB"
  assert_defined "shared finding_type_normalize now present" "finding_type_normalize"
  assert_defined "shared domain_default_finding_type now present" "domain_default_finding_type"
  assert_eq "delegated resolve: explicit alias still wins (perf -> performance-risk)" \
    "performance-risk" "$(_ledger_resolve_finding_type "perf" "security")"
  assert_eq "delegated resolve: domain fallback still maps (database -> reliability-bug)" \
    "reliability-bug" "$(_ledger_resolve_finding_type "" "database")"
  assert_eq "delegated resolve: still never empty (unknown -> maintainability)" \
    "maintainability" "$(_ledger_resolve_finding_type "bogus" "marketing")"
  # The shared and ledger resolvers must agree on the file-reading entry point too.
  delf="$TMPDIR/delegate.md"
  cat > "$delf" <<'EOF'
---
title: "[high] Delegation parity"
severity: high
domain: security
---

## Summary
type: SHOULD_NOT_WIN
EOF
  assert_eq "core.sh finding_resolve_type agrees with ledger value resolver (security domain)" \
    "security-vulnerability" "$(finding_resolve_type "$delf")"
else
  fail_with "lib/core.sh exists for the delegation section" "missing: $CORE_LIB"
fi

finish
