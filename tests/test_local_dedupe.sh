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

# Tests for issue #343: deterministic, model-free dedupe over the --local
# markdown output (the NNN-<slug>.md files each lens agent writes under
# <output_dir>/<domain>/<lens>/). These are TDD red-phase tests written BEFORE
# lib/local-dedupe.sh exists; they pin the behavioral contract the implementer
# must satisfy. NO AI models are invoked anywhere (project rule + issue AC).
#
# Contract under test (public interface, grounded in research.md + the issue):
#   dedupe_local_markdown <output_dir>      (lib/local-dedupe.sh)
#     Walks the --local md tree, groups near-duplicate findings using the SAME
#     match + canonical-selection helpers built for the manifest path
#     (_dedupe_is_match cross-domain / _dedupe_pick_canonical), then marks the
#     files IN PLACE — never deletes or moves them:
#       * each NON-canonical file gains `status: duplicate` + a `duplicate_of:`
#         frontmatter link to the canonical file, and is NOT removed;
#       * the canonical file gains an `also_reported_by:` frontmatter list
#         referencing each non-canonical contributor (lens/domain/path);
#       * singletons and files without valid frontmatter are left byte-identical.
#     Deterministic and idempotent: re-running over an already-deduped tree
#     produces a byte-identical tree. Returns 0 on success / no-op.
#
# Acceptance-criteria coverage:
#   AC1 runs gated on $LOCAL_MODE  -> wiring section (repolens.sh sources the lib
#                                     and invokes dedupe_local_markdown).
#   AC2 two cross-lens/domain dups collapse to one canonical + also_reported_by;
#       duplicate clearly marked, not deleted          -> "core collapse" section.
#   AC3 reuses canonical-selection + match helpers     -> observable: the higher-
#       severity record is chosen canonical (the _dedupe_pick_canonical rule) and
#       the pair collapses ACROSS domains (the cross-domain _dedupe_is_match rule).
#   AC4 idempotent (re-run = no further changes)        -> "idempotency" section.
#   AC5 non-duplicate files untouched                   -> "untouched" section.
#   AC6 no model invocation anywhere                    -> "no model" section.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
LEDGER_LIB="$SCRIPT_DIR/lib/ledger.sh"
SYNTH_LIB="$SCRIPT_DIR/lib/synthesize.sh"
DEDUPE_LIB="$SCRIPT_DIR/lib/dedupe.sh"
LOCAL_DEDUPE_LIB="$SCRIPT_DIR/lib/local-dedupe.sh"
REPOLENS="$SCRIPT_DIR/repolens.sh"

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

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file $path"
  fi
}

# assert_grep <desc> <ERE-pattern> <file> — passes when the pattern is present.
assert_grep() {
  local desc="$1" pat="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]] && grep -qE "$pat" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "pattern not found: $pat (in $file)"
  fi
}

# assert_not_grep <desc> <ERE-pattern> <file> — passes when the pattern is absent.
assert_not_grep() {
  local desc="$1" pat="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]] && grep -qE "$pat" "$file"; then
    fail_with "$desc" "unexpected pattern present: $pat (in $file)"
  else
    pass_with "$desc"
  fi
}

# assert_order <desc> <ERE-first> <ERE-second> <file> — passes when both patterns
# are present AND the first matches on an earlier line than the second. Used to
# pin the deterministic sort of the also_reported_by: list.
assert_order() {
  local desc="$1" first="$2" second="$3" file="$4"
  local ln_first ln_second
  TOTAL=$((TOTAL + 1))
  ln_first="$(grep -nE "$first" "$file" 2>/dev/null | head -1 | cut -d: -f1)"
  ln_second="$(grep -nE "$second" "$file" 2>/dev/null | head -1 | cut -d: -f1)"
  if [[ -n "$ln_first" && -n "$ln_second" && "$ln_first" -lt "$ln_second" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "expected '$first' (line ${ln_first:-none}) before '$second' (line ${ln_second:-none}) in $file"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

sha_of()    { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
# Hash of the WHOLE tree (paths + contents, deterministic order) — drives the
# idempotency assertion without copying snapshots around.
tree_hash() {
  find "$1" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null
}

TMP_PARENT="$SCRIPT_DIR/logs/test-local-dedupe"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

# Pin the match thresholds so the fixtures collapse for the right reason and stay
# stable against future default tuning (#353). Identical normalized titles score
# 1.0 (10000) >= the 0.85 primary bar, so the pair matches title-alone regardless
# of location enrichment.
export DEDUPE_TITLE_SIM_PRIMARY=8500
export DEDUPE_TITLE_SIM_SECONDARY=6000

# --- Source the dependency libs FIRST (so behavior is exercisable even if the
# new lib relies on its caller having sourced the helper modules), then the lib
# under test. Re-sourcing is harmless if local-dedupe.sh also self-sources. -----
# shellcheck source=/dev/null
source "$CORE_LIB"
# shellcheck source=/dev/null
source "$LEDGER_LIB"
# shellcheck source=/dev/null
source "$SYNTH_LIB"
# shellcheck source=/dev/null
source "$DEDUPE_LIB"

# Red-phase gate: the lib and its entry point must exist. Bail cleanly otherwise
# (implementation pending) — same discipline as tests/test_ledger_from_local.sh.
TOTAL=$((TOTAL + 1))
if [[ -f "$LOCAL_DEDUPE_LIB" ]]; then
  pass_with "lib/local-dedupe.sh exists"
else
  fail_with "lib/local-dedupe.sh exists" "missing: $LOCAL_DEDUPE_LIB (implementation pending — TDD red phase)"
  finish
fi

# shellcheck source=/dev/null
source "$LOCAL_DEDUPE_LIB"

TOTAL=$((TOTAL + 1))
if declare -F dedupe_local_markdown >/dev/null 2>&1; then
  pass_with "dedupe_local_markdown is defined after sourcing lib/local-dedupe.sh"
else
  fail_with "dedupe_local_markdown is defined after sourcing lib/local-dedupe.sh" \
    "function not found — implementation pending (TDD red phase)"
  finish
fi

# Helper: write a --local finding file with the production frontmatter contract.
# $1 path  $2 title  $3 severity  $4 domain  $5 lens
write_finding() {
  local path="$1" title="$2" sev="$3" domain="$4" lens="$5"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
---
title: "$title"
severity: $sev
type: security-vulnerability
domain: $domain
lens: $lens
labels:
  - "$lens"
---

## Summary
Synthetic finding for the local-dedupe test.

## Validation
- proof_anchors — src/server/mtls.go:88
EOF
}

# ===========================================================================
# CORE COLLAPSE (AC2 + AC3): two findings of the SAME thing, reported by two
# DIFFERENT lenses in two DIFFERENT domains, with identical (severity-prefixed)
# titles -> they must collapse cross-domain. The HIGH-severity one is the
# deterministic canonical (the _dedupe_pick_canonical rule); the LOW one is the
# duplicate. A third, unrelated finding is the control that must stay untouched.
# ===========================================================================
out="$TMPDIR/output"
canon_md="$out/code/auth/001-empty-cn-mtls-bypass.md"
dup_md="$out/deployment/tls/007-empty-cn-mtls-bypass.md"
unique_md="$out/code/misc/003-sql-injection-user-search.md"

dup_title='Empty CN allows mTLS client authentication bypass'
write_finding "$canon_md"  "[high] $dup_title"  high   code        auth   # canonical (highest severity)
write_finding "$dup_md"    "[low] $dup_title"   low    deployment  tls    # cross-domain duplicate
write_finding "$unique_md" "[medium] SQL injection in the user search endpoint" \
  medium code misc

unique_before="$(sha_of "$unique_md")"

echo "=== core: cross-domain collapse, canonical = highest severity ==="

dedupe_local_markdown "$out"; rc=$?
assert_rc "dedupe_local_markdown returns 0 on a tree with one duplicate group" 0 "$rc"

# Duplicate is MARKED, not deleted.
assert_file_exists "the duplicate file is not deleted" "$dup_md"
assert_grep "duplicate file frontmatter is marked status: duplicate" \
  '^[[:space:]]*status:[[:space:]]*["'\'']?duplicate' "$dup_md"
assert_grep "duplicate file carries a duplicate_of frontmatter link" \
  '^[[:space:]]*duplicate_of:' "$dup_md"
assert_grep "duplicate_of links to the canonical file" \
  '001-empty-cn-mtls-bypass\.md' "$dup_md"

# Canonical KEPT and annotated with also_reported_by referencing the duplicate.
assert_file_exists "the canonical file is kept" "$canon_md"
assert_grep "canonical file gains an also_reported_by frontmatter list" \
  '^[[:space:]]*also_reported_by:' "$canon_md"
assert_grep "canonical also_reported_by references the duplicate's lens/domain/path" \
  '(\bdeployment\b|007-empty-cn-mtls-bypass\.md)' "$canon_md"
# The canonical is the survivor — it is NOT itself marked a duplicate.
assert_not_grep "canonical file is NOT marked status: duplicate" \
  '^[[:space:]]*status:[[:space:]]*["'\'']?duplicate' "$canon_md"

# AC5: the unrelated finding is byte-identical after the pass.
assert_eq "the unique (non-duplicate) file is byte-identical after the pass" \
  "$unique_before" "$(sha_of "$unique_md")"

echo "=== idempotency (AC4): a second pass changes nothing ==="

h1="$(tree_hash "$out")"
dedupe_local_markdown "$out"; rc=$?
assert_rc "second dedupe pass returns 0" 0 "$rc"
h2="$(tree_hash "$out")"
TOTAL=$((TOTAL + 1))
if [[ "$h1" == "$h2" ]]; then
  pass_with "re-running over an already-deduped tree is byte-identical (idempotent)"
else
  fail_with "re-running over an already-deduped tree is byte-identical (idempotent)" \
    "tree changed on the second run"
fi

echo "=== untouched guarantees (AC5): singleton + frontmatter-less file ==="

# A tree where the only would-be pair is broken by a malformed (frontmatter-less)
# file: the parser skips it, so it never groups and must stay byte-identical, and
# the remaining valid file is a lone singleton -> also untouched.
mixed="$TMPDIR/mixed"
single_md="$mixed/code/auth/001-only-one.md"
garbage_md="$mixed/code/auth/002-no-frontmatter.md"
write_finding "$single_md" "[high] A lonely unique finding with no twin" high code auth
mkdir -p "$(dirname "$garbage_md")"
cat > "$garbage_md" <<'EOF'
This file has no YAML frontmatter at all.
status: should-never-be-added
EOF
single_before="$(sha_of "$single_md")"
garbage_before="$(sha_of "$garbage_md")"

dedupe_local_markdown "$mixed"; rc=$?
assert_rc "dedupe_local_markdown returns 0 on a no-duplicate tree" 0 "$rc"
assert_eq "a singleton finding is left byte-identical" \
  "$single_before" "$(sha_of "$single_md")"
assert_eq "a frontmatter-less file is left byte-identical (never marked)" \
  "$garbage_before" "$(sha_of "$garbage_md")"

echo "=== no-op cases: empty dir and single-file dir ==="

empty="$TMPDIR/empty"
mkdir -p "$empty"
dedupe_local_markdown "$empty"; rc=$?
assert_rc "empty output dir is a no-op success (exit 0)" 0 "$rc"

solo="$TMPDIR/solo"
solo_md="$solo/code/auth/001-solo.md"
write_finding "$solo_md" "[high] The one and only finding here" high code auth
solo_before="$(sha_of "$solo_md")"
dedupe_local_markdown "$solo"; rc=$?
assert_rc "single-file output dir is a no-op success (exit 0)" 0 "$rc"
assert_eq "the single file is byte-identical (no group of size >= 2)" \
  "$solo_before" "$(sha_of "$solo_md")"

echo "=== AC6: no AI model is invoked anywhere in the pass ==="

# The pass must be pure bash/jq/awk. Strip whole-line comments (so a doc header
# mentioning a model name doesn't false-positive) and assert no agent CLI is
# invoked as a command in the actual code.
TOTAL=$((TOTAL + 1))
code_only="$(grep -vE '^[[:space:]]*#' "$LOCAL_DEDUPE_LIB" 2>/dev/null)"
if grep -qE '(^|[^[:alnum:]_/-])(claude|codex|opencode|sparc|run_agent)([^[:alnum:]_]|$)' <<<"$code_only"; then
  fail_with "no AI agent CLI is invoked anywhere in lib/local-dedupe.sh" \
    "found an agent-CLI reference in non-comment code"
else
  pass_with "no AI agent CLI is invoked anywhere in lib/local-dedupe.sh"
fi

echo "=== AC1: the pass is wired into repolens.sh's --local finalize ==="

# Structural wiring check (the full --local pipeline is out of scope for a unit
# test — it would require a real or mocked agent). The entry point must source
# the new lib and invoke the pass.
assert_grep "repolens.sh sources lib/local-dedupe.sh" \
  'local-dedupe(\.sh)?' "$REPOLENS"
assert_grep "repolens.sh invokes dedupe_local_markdown" \
  'dedupe_local_markdown' "$REPOLENS"

# ===========================================================================
# MULTI-MEMBER GROUP (AC2 + AC3, deeper): the core section above only ever
# exercises a 2-member group (1 canonical + 1 duplicate). A group of THREE (one
# finding seen by three lenses across three domains) is the path that actually
# drives (a) the inner contributor loop marking MORE THAN ONE duplicate file,
# (b) the multi-entry `also_reported_by:` list and its deterministic
# sort_by(domain,lens,path) ordering, and (c) the multi-entry strip on re-run.
# Canonical = the single HIGH file; the LOW (code/auth) and MEDIUM (infra/net)
# files are both duplicates of it. also_reported_by is sorted by domain, so the
# `code` contributor must appear before the `infra` one.
# ===========================================================================
echo "=== multi-member group: 3 lenses/domains collapse to one canonical ==="

m_out="$TMPDIR/multi"
m_canon="$m_out/deployment/tls/007-empty-cn-mtls-bypass.md"  # high  -> canonical
m_dup_lo="$m_out/code/auth/001-empty-cn-mtls-bypass.md"      # low   -> duplicate
m_dup_md="$m_out/infra/net/002-empty-cn-mtls-bypass.md"      # medium-> duplicate
m_unique="$m_out/code/misc/003-sql-injection.md"             # control
m_title='Empty CN allows mTLS client authentication bypass'

write_finding "$m_canon"  "[high] $m_title"   high   deployment  tls
write_finding "$m_dup_lo" "[low] $m_title"    low    code        auth
write_finding "$m_dup_md" "[medium] $m_title" medium infra       net
write_finding "$m_unique" "[medium] SQL injection in the user search endpoint" \
  medium code misc
m_unique_before="$(sha_of "$m_unique")"

dedupe_local_markdown "$m_out"; rc=$?
assert_rc "multi-member: dedupe_local_markdown returns 0" 0 "$rc"

# The single highest-severity file wins the canonical slot (not marked a dup).
assert_not_grep "multi-member: high-severity file is canonical (not status: duplicate)" \
  '^[[:space:]]*status:[[:space:]]*["'\'']?duplicate' "$m_canon"
# BOTH lower-severity files are marked duplicate and linked to the SAME canonical.
assert_grep "multi-member: low file is marked status: duplicate" \
  '^[[:space:]]*status:[[:space:]]*["'\'']?duplicate' "$m_dup_lo"
assert_grep "multi-member: medium file is marked status: duplicate" \
  '^[[:space:]]*status:[[:space:]]*["'\'']?duplicate' "$m_dup_md"
# duplicate_of is the canonical path RELATIVE to output_dir (no leading slash, no
# absolute tmp prefix) — the basename-only check in the core section would also
# pass for an absolute path, so pin the relative form precisely here.
assert_grep "multi-member: low file duplicate_of is the canonical RELATIVE path" \
  '^[[:space:]]*duplicate_of:[[:space:]]*deployment/tls/007-empty-cn-mtls-bypass\.md[[:space:]]*$' "$m_dup_lo"
assert_grep "multi-member: medium file duplicate_of is the canonical RELATIVE path" \
  '^[[:space:]]*duplicate_of:[[:space:]]*deployment/tls/007-empty-cn-mtls-bypass\.md[[:space:]]*$' "$m_dup_md"
assert_not_grep "multi-member: duplicate_of is not an absolute path" \
  '^[[:space:]]*duplicate_of:[[:space:]]*/' "$m_dup_lo"

# The canonical lists BOTH contributors in its also_reported_by, by RELATIVE path,
# sorted by domain (code before infra).
assert_grep "multi-member: canonical also_reported_by references the code/auth contributor (relative path)" \
  '^[[:space:]]*markdown_path:[[:space:]]*code/auth/001-empty-cn-mtls-bypass\.md[[:space:]]*$' "$m_canon"
assert_grep "multi-member: canonical also_reported_by references the infra/net contributor (relative path)" \
  '^[[:space:]]*markdown_path:[[:space:]]*infra/net/002-empty-cn-mtls-bypass\.md[[:space:]]*$' "$m_canon"
assert_order "multi-member: also_reported_by is domain-sorted (code before infra)" \
  'markdown_path:[[:space:]]*code/auth/' 'markdown_path:[[:space:]]*infra/net/' "$m_canon"

# A human-visible body note is appended (sentinel-wrapped) to every marked file.
assert_grep "multi-member: canonical carries the dedupe body note sentinel" \
  'repolens-dedupe:begin' "$m_canon"
assert_grep "multi-member: low duplicate carries the dedupe body note sentinel" \
  'repolens-dedupe:begin' "$m_dup_lo"
assert_grep "multi-member: medium duplicate carries the dedupe body note sentinel" \
  'repolens-dedupe:begin' "$m_dup_md"

# Control finding untouched, and the whole 3-member tree is idempotent (the
# multi-entry also_reported_by strip-then-readd is a fixed point).
assert_eq "multi-member: the unrelated control file is byte-identical" \
  "$m_unique_before" "$(sha_of "$m_unique")"
m_h1="$(tree_hash "$m_out")"
dedupe_local_markdown "$m_out"; rc=$?
assert_rc "multi-member: second pass returns 0" 0 "$rc"
m_h2="$(tree_hash "$m_out")"
TOTAL=$((TOTAL + 1))
if [[ "$m_h1" == "$m_h2" ]]; then
  pass_with "multi-member: re-running the 3-member group is byte-identical (idempotent)"
else
  fail_with "multi-member: re-running the 3-member group is byte-identical (idempotent)" \
    "tree changed on the second run"
fi

# ===========================================================================
# MULTIPLE INDEPENDENT GROUPS (AC2): the existing tree always has exactly ONE
# duplicate group, so the outer group loop / groups_marked>1 path never runs.
# Two unrelated findings, each reported by two lenses, must collapse into TWO
# separate groups — each duplicate links ONLY to its OWN canonical, never
# cross-linked into the other group.
# ===========================================================================
echo "=== multiple independent duplicate groups in one tree ==="

g_out="$TMPDIR/twogroups"
ga_canon="$g_out/deployment/tls/007-empty-cn.md"   # group A canonical (high)
ga_dup="$g_out/code/auth/001-empty-cn.md"          # group A duplicate (low)
gb_canon="$g_out/code/secrets/004-aws-key.md"      # group B canonical (critical)
gb_dup="$g_out/infra/scan/009-aws-key.md"          # group B duplicate (medium)
ga_title='Empty CN allows mTLS client authentication bypass'
gb_title='Hardcoded AWS secret key committed to the repository'

write_finding "$ga_canon" "[high] $ga_title"     high     deployment tls
write_finding "$ga_dup"   "[low] $ga_title"      low      code       auth
write_finding "$gb_canon" "[critical] $gb_title" critical code       secrets
write_finding "$gb_dup"   "[medium] $gb_title"   medium   infra      scan

dedupe_local_markdown "$g_out"; rc=$?
assert_rc "two-groups: dedupe_local_markdown returns 0" 0 "$rc"

# Each group's duplicate links to its OWN canonical.
assert_grep "two-groups: group-A duplicate links to group-A canonical" \
  '^[[:space:]]*duplicate_of:[[:space:]]*deployment/tls/007-empty-cn\.md[[:space:]]*$' "$ga_dup"
assert_grep "two-groups: group-B duplicate links to group-B canonical" \
  '^[[:space:]]*duplicate_of:[[:space:]]*code/secrets/004-aws-key\.md[[:space:]]*$' "$gb_dup"
# No cross-contamination between the groups.
assert_not_grep "two-groups: group-A duplicate does NOT link to group-B canonical" \
  'aws-key' "$ga_dup"
assert_not_grep "two-groups: group-B duplicate does NOT link to group-A canonical" \
  'empty-cn' "$gb_dup"
# Both canonicals are survivors annotated with their own contributor.
assert_not_grep "two-groups: group-A canonical is not marked duplicate" \
  '^[[:space:]]*status:[[:space:]]*["'\'']?duplicate' "$ga_canon"
assert_not_grep "two-groups: group-B canonical is not marked duplicate" \
  '^[[:space:]]*status:[[:space:]]*["'\'']?duplicate' "$gb_canon"
assert_grep "two-groups: group-A canonical references its code/auth contributor" \
  '^[[:space:]]*markdown_path:[[:space:]]*code/auth/001-empty-cn\.md[[:space:]]*$' "$ga_canon"
assert_grep "two-groups: group-B canonical references its infra/scan contributor" \
  '^[[:space:]]*markdown_path:[[:space:]]*infra/scan/009-aws-key\.md[[:space:]]*$' "$gb_canon"

finish
