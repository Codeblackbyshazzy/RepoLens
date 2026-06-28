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

# Tests for issue #353: make near-duplicate title-similarity thresholds
# configurable via the environment, with safe validation.
#
# Behavioral contract under test (from the issue acceptance criteria):
#   - validate_manifest's primary title-similarity bar is read from
#     DEDUPE_TITLE_SIM_PRIMARY (Jaccard x10000, default 8500). When unset,
#     behavior is identical to today (strict '>' against 8500).
#   - Lowering the primary threshold flags a pair that previously passed;
#     raising it (>= a pair's similarity) lets a pair that previously failed
#     pass. The two consumers (validate_manifest in lib/synthesize.sh and
#     _dedupe_is_match in lib/dedupe.sh) share the same DEDUPE_TITLE_SIM_*
#     knobs.
#   - Invalid input (non-numeric / negative) must fall back to the default
#     with a log_warn, and must NEVER crash. Today an invalid value such as
#     DEDUPE_TITLE_SIM_PRIMARY=garbage makes _dedupe_is_match abort under
#     `set -u` ("unbound variable") — this file pins that down as a crash to
#     close.
#   - Out-of-range numeric values > 10000 are NOT clamped: they remain valid
#     "effectively disabled" sentinels (the secondary-off trick used by
#     tests/test_dedupe_match.sh). Resolving them must not warn.
#
# Design notes:
#   - We test PUBLIC behavior: the validate_manifest exit code + its stderr,
#     and the _dedupe_is_match exit code + its stderr. We never assert on the
#     name or shape of any internal resolver helper.
#   - The similarity of the crafted "partial overlap" pair is computed at
#     runtime from the existing public primitives, so the fixtures stay valid
#     if the n-gram primitive is ever retuned (the test asserts only the
#     direction-of-change relative to that measured value).
#   - Potentially-invalid env values are exercised inside a subshell so that a
#     `set -u` crash in buggy/naive code is observable (non-zero exit + stderr
#     signature) instead of killing this test runner.
# shellcheck disable=SC2329

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"
SYNTHESIZE_LIB="$SCRIPT_DIR/lib/synthesize.sh"
DEDUPE_LIB="$SCRIPT_DIR/lib/dedupe.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-dedupe-threshold"
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
    fail_with "$desc" "Expected non-zero exit"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in: $haystack"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpectedly found '$needle' in: $haystack"
  fi
}

assert_true() {
  local desc="$1" rc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$rc" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected rc 0, got $rc"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# Writes a 2-entry, schema-valid manifest whose only possible failure is the
# title-similarity check. Titles are interpolated; they must not contain
# double-quotes or backslashes (the fixtures below never do).
write_pair_manifest() {
  local path="$1" ta="$2" tb="$3"
  cat > "$path" <<JSON
[
  {
    "cluster_id": "pair::a",
    "title": "$ta",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body a"
  },
  {
    "cluster_id": "pair::b",
    "title": "$tb",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-2/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body b"
  }
]
JSON
}

# Writes a 3-entry, schema-valid manifest (same schema as write_pair_manifest).
# Three entries => three pairwise comparisons in validate_manifest's O(n^2) loop,
# which is what makes "the threshold is resolved once, not per pair" observable.
# Titles must not contain double-quotes or backslashes.
write_triple_manifest() {
  local path="$1" ta="$2" tb="$3" tc="$4"
  cat > "$path" <<JSON
[
  {
    "cluster_id": "triple::a",
    "title": "$ta",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body a"
  },
  {
    "cluster_id": "triple::b",
    "title": "$tb",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-2/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body b"
  },
  {
    "cluster_id": "triple::c",
    "title": "$tc",
    "severity": "high",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-1/rounds/round-3/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "body c"
  }
]
JSON
}

ERRFILE="$TMPDIR/stderr.txt"

# Run validate_manifest in a SUBSHELL so a `set -u` crash in naive code (an
# invalid env value reaching the arithmetic directly) is contained and shows up
# as stderr + exit code, instead of aborting this whole test process.
# Sets VM_RC; stderr is written to ERRFILE.
run_validate() {
  ( validate_manifest "$1" ) 2>"$ERRFILE"
  VM_RC=$?
}

# Same idea for the _dedupe_is_match predicate.
run_match() {
  ( _dedupe_is_match "$1" "$2" ) 2>"$ERRFILE"
  DM_RC=$?
}

if [[ ! -f "$SYNTHESIZE_LIB" ]]; then
  echo "  FAIL: lib/synthesize.sh missing at $SYNTHESIZE_LIB"
  exit 1
fi
if [[ ! -f "$DEDUPE_LIB" ]]; then
  echo "  FAIL: lib/dedupe.sh missing at $DEDUPE_LIB"
  exit 1
fi

# shellcheck source=/dev/null
source "$CORE_LIB"
# shellcheck source=/dev/null
source "$SYNTHESIZE_LIB"
# shellcheck source=/dev/null
source "$DEDUPE_LIB"

echo "=== fixture sanity: crafted partial-overlap pair sits strictly between 0 and the default 8500 ==="

# Two titles that share the first three trigrams but differ in the last three:
# "...writing files to disk" vs "...writing logs to disk". Jaccard = 3/9.
TITLE_A="[high] Validate upload filenames before writing files to disk"
TITLE_B="[high] Validate upload filenames before writing logs to disk"

NA="$(_synthesize_normalize_title "$TITLE_A")"
NB="$(_synthesize_normalize_title "$TITLE_B")"
SIM="$(_synthesize_jaccard_x10000 "$(_synthesize_title_ngrams "$NA")" "$(_synthesize_title_ngrams "$NB")")"

TOTAL=$((TOTAL + 1))
if (( SIM > 0 && SIM < 8500 )); then
  pass_with "partial-overlap pair similarity ($SIM) is in (0, 8500)"
else
  fail_with "partial-overlap pair similarity ($SIM) is in (0, 8500)" \
    "fixture rot: expected 0 < sim < 8500, got $SIM"
  finish
fi

PARTIAL="$TMPDIR/partial.json"
write_pair_manifest "$PARTIAL" "$TITLE_A" "$TITLE_B"

IDENTICAL="$TMPDIR/identical.json"
write_pair_manifest "$IDENTICAL" "$TITLE_A" "$TITLE_A"

echo ""
echo "=== validate_manifest: DEDUPE_TITLE_SIM_PRIMARY is honored (env read, both directions) ==="

# Baseline (env unset): the partial pair passes at the default 8500 bar.
run_validate "$PARTIAL"
assert_success "default threshold: partial-overlap pair passes (sim < 8500)" "$VM_RC"

# Lower the primary bar just below the pair's measured similarity -> the
# previously-passing pair now flags as a near-duplicate.
export DEDUPE_TITLE_SIM_PRIMARY=$((SIM - 1))
run_validate "$PARTIAL"
LOWER_ERR="$(cat "$ERRFILE")"
unset DEDUPE_TITLE_SIM_PRIMARY
assert_failure "lowered threshold flags a pair that previously passed" "$VM_RC"
assert_contains "lowered-threshold failure reports a near-duplicate" \
  "near-duplicate titles" "$LOWER_ERR"

# Baseline (env unset): identical titles flag at the default 8500 bar (sim 10000).
run_validate "$IDENTICAL"
assert_failure "default threshold: identical titles flag (sim 10000 > 8500)" "$VM_RC"

# Raise the primary bar to the maximum (10000). With the preserved strict '>',
# 10000 > 10000 is false, so the previously-failing identical pair now passes.
export DEDUPE_TITLE_SIM_PRIMARY=10000
run_validate "$IDENTICAL"
unset DEDUPE_TITLE_SIM_PRIMARY
assert_success "raised threshold (10000) lets a pair that previously failed pass" "$VM_RC"

echo ""
echo "=== validate_manifest: invalid input falls back to default + log_warn, never crashes ==="

# Non-numeric: must still flag the identical pair (fallback to default 8500),
# emit a warning, and must NOT crash (no `set -u` unbound-variable abort).
export DEDUPE_TITLE_SIM_PRIMARY=garbage
run_validate "$IDENTICAL"
BAD_ERR="$(cat "$ERRFILE")"
unset DEDUPE_TITLE_SIM_PRIMARY
assert_failure "non-numeric threshold falls back to default (identical pair still flags)" "$VM_RC"
assert_contains "non-numeric threshold emits a WARN" "WARN" "$BAD_ERR"
assert_not_contains "non-numeric threshold does not crash (no unbound variable)" \
  "unbound variable" "$BAD_ERR"
assert_contains "non-numeric fallback preserves the default near-duplicate report" \
  "near-duplicate titles" "$BAD_ERR"

# Negative: same fallback-and-warn contract.
export DEDUPE_TITLE_SIM_PRIMARY=-5
run_validate "$IDENTICAL"
NEG_ERR="$(cat "$ERRFILE")"
unset DEDUPE_TITLE_SIM_PRIMARY
assert_failure "negative threshold falls back to default (identical pair still flags)" "$VM_RC"
assert_contains "negative threshold emits a WARN" "WARN" "$NEG_ERR"
assert_not_contains "negative threshold does not crash (no unbound variable)" \
  "unbound variable" "$NEG_ERR"

echo ""
echo "=== _dedupe_is_match: invalid input is hardened (no crash, no match-everything) ==="

# A low-similarity, location-less pair: neither the primary nor the secondary
# branch should fire under any valid threshold resolution.
LOW_A='{"domain":"authorization","title":"Race condition in session cache eviction"}'
LOW_B='{"domain":"performance","title":"N plus one query on the dashboard endpoint"}'

# Non-numeric primary today aborts the predicate under `set -u`. After the fix
# it must resolve to the default 8500 -> low pair does NOT match, with a warning.
export DEDUPE_TITLE_SIM_PRIMARY=garbage
run_match "$LOW_A" "$LOW_B"
DM_BAD_ERR="$(cat "$ERRFILE")"
unset DEDUPE_TITLE_SIM_PRIMARY
assert_failure "garbage primary -> low-similarity pair does NOT match (fallback to default)" "$DM_RC"
assert_not_contains "garbage primary does not crash the predicate (no unbound variable)" \
  "unbound variable" "$DM_BAD_ERR"
assert_contains "garbage primary emits a WARN" "WARN" "$DM_BAD_ERR"

# Negative primary today makes every pair match (>= -5 is always true). After
# the fix it must resolve to the default 8500 -> no match.
export DEDUPE_TITLE_SIM_PRIMARY=-5
run_match "$LOW_A" "$LOW_B"
unset DEDUPE_TITLE_SIM_PRIMARY
assert_failure "negative primary -> low-similarity pair does NOT match (no match-everything)" "$DM_RC"

echo ""
echo "=== threshold resolution: numeric values > 10000 are NOT clamped (disable sentinel preserved) ==="

# Cross-domain, same-location pair with sub-primary title similarity (~6666).
# It matches via the secondary branch at the default 6000, but a secondary of
# 99999 must disable that branch (no pair can reach 99999). If an implementation
# clamped > 10000 back to the default, this pair would wrongly match again.
XDOMAIN_A='{
  "domain":"authorization",
  "primary_location":"src/mtls.go:42",
  "title":"[high] mTLS accepts certificates with empty common name"
}'
XDOMAIN_B='{
  "domain":"cryptography",
  "primary_location":"src/mtls.go:42:7",
  "title":"[critical] mTLS accepts certificates with empty common subject"
}'

export DEDUPE_TITLE_SIM_PRIMARY=8500
export DEDUPE_TITLE_SIM_SECONDARY=99999
run_match "$XDOMAIN_A" "$XDOMAIN_B"
SENT_ERR="$(cat "$ERRFILE")"
unset DEDUPE_TITLE_SIM_PRIMARY DEDUPE_TITLE_SIM_SECONDARY
assert_failure "secondary=99999 disables the location branch (no upper-bound clamp)" "$DM_RC"
assert_not_contains "valid numeric 99999 is not treated as invalid (no spurious WARN)" \
  "WARN" "$SENT_ERR"

echo ""
echo "=== validate_manifest: leading-zero numeric input is decimal-normalized, not octal-trapped ==="

# "08500" MATCHES ^[0-9]+$, so it is ACCEPTED (not a fallback) and must be read
# as decimal 8500 via $((10#...)). Without that base-10 prefix, bash arithmetic
# treats a leading-zero literal as octal and aborts with "value too great for
# base" on the digits 8/5 -> the threshold would crash, not resolve. This is a
# distinct path from both the plain-numeric and the garbage-fallback cases.
export DEDUPE_TITLE_SIM_PRIMARY=08500
run_validate "$IDENTICAL"
LZ_VM_ERR="$(cat "$ERRFILE")"
unset DEDUPE_TITLE_SIM_PRIMARY
assert_failure "leading-zero 08500 resolves to decimal 8500 -> identical pair still flags" "$VM_RC"
assert_not_contains "leading-zero input is not octal-trapped (no 'value too great for base')" \
  "value too great for base" "$LZ_VM_ERR"
assert_not_contains "leading-zero input does not crash (no unbound variable)" \
  "unbound variable" "$LZ_VM_ERR"
assert_not_contains "leading-zero input is valid numeric -> emits no WARN" \
  "WARN" "$LZ_VM_ERR"

echo ""
echo "=== threshold resolver: stdout carries ONLY the numeric value (warnings go to stderr) ==="

# The resolver's stdout is captured by callers as the threshold value, so any
# warning text must go to stderr only. These assertions pin that contract
# directly: a regression that printed the warning to stdout would corrupt the
# captured threshold (e.g. "WARN ... 8500") without tripping the public-path
# "unbound variable" / "still flags" guards above.

# Unset -> stdout is exactly the supplied default, nothing else.
unset DEDUPE_TITLE_SIM_PRIMARY 2>/dev/null || true
RESOLVED="$(_dedupe_resolve_sim_threshold DEDUPE_TITLE_SIM_PRIMARY 8500 2>/dev/null)"
TOTAL=$((TOTAL + 1))
if [[ "$RESOLVED" == "8500" ]]; then
  pass_with "unset env -> resolver stdout is exactly the default (8500)"
else
  fail_with "unset env -> resolver stdout is exactly the default (8500)" "got '$RESOLVED'"
fi

# Valid numeric -> echoed verbatim on stdout.
export DEDUPE_TITLE_SIM_PRIMARY=7000
RESOLVED="$(_dedupe_resolve_sim_threshold DEDUPE_TITLE_SIM_PRIMARY 8500 2>/dev/null)"
unset DEDUPE_TITLE_SIM_PRIMARY
TOTAL=$((TOTAL + 1))
if [[ "$RESOLVED" == "7000" ]]; then
  pass_with "valid numeric -> resolver echoes the override (7000) on stdout"
else
  fail_with "valid numeric -> resolver echoes the override (7000) on stdout" "got '$RESOLVED'"
fi

# Leading-zero -> decimal-normalized value on stdout, no octal error on stderr.
export DEDUPE_TITLE_SIM_PRIMARY=08500
RESOLVED="$(_dedupe_resolve_sim_threshold DEDUPE_TITLE_SIM_PRIMARY 8500 2>"$ERRFILE")"
LZ_RES_ERR="$(cat "$ERRFILE")"
unset DEDUPE_TITLE_SIM_PRIMARY
TOTAL=$((TOTAL + 1))
if [[ "$RESOLVED" == "8500" ]]; then
  pass_with "leading-zero override -> resolver stdout normalized to decimal 8500"
else
  fail_with "leading-zero override -> resolver stdout normalized to decimal 8500" "got '$RESOLVED'"
fi
assert_not_contains "leading-zero override -> resolver emits no octal error" \
  "value too great for base" "$LZ_RES_ERR"

# Garbage -> stdout is PURELY the default; the warning must NOT leak onto stdout.
export DEDUPE_TITLE_SIM_PRIMARY=garbage
RESOLVED="$(_dedupe_resolve_sim_threshold DEDUPE_TITLE_SIM_PRIMARY 8500 2>/dev/null)"
unset DEDUPE_TITLE_SIM_PRIMARY
TOTAL=$((TOTAL + 1))
if [[ "$RESOLVED" == "8500" ]]; then
  pass_with "garbage override -> resolver stdout is exactly the default (warning stays off stdout)"
else
  fail_with "garbage override -> resolver stdout is exactly the default (warning stays off stdout)" "got '$RESOLVED'"
fi
assert_not_contains "garbage override -> resolver stdout carries no WARN text" "WARN" "$RESOLVED"

echo ""
echo "=== resolver survives a partially-initialized logging module (set -u hardening) ==="

# Regression guard for the QG crash. When log_warn is DEFINED (lib/logging.sh
# sourced) but its module-level globals are not initialized — e.g. the function
# reaches a process without its top-level init having run, or init_logging was
# never called — log_warn reads _REPOLENS_LOG_* directly. Under `set -u` an unset
# one aborts the CALLER mid-call, which empties the threshold the resolver was
# about to print and leaks "unbound variable" to stderr (every pair then matches,
# because empty resolves to 0 in the arithmetic). The resolver/warn helper must
# tolerate that: still emit the default on stdout, still warn, never crash.
#
# This path is environment-INDEPENDENT: it forces log_warn to exist and then
# strips the globals, so it pins the bug regardless of whether the surrounding
# harness happens to define log_warn. Run in a subshell so a regressed `set -u`
# abort is observed (empty stdout / unbound-variable stderr) rather than killing
# this runner.
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"
if [[ -f "$LOGGING_LIB" ]]; then
  export DEDUPE_TITLE_SIM_PRIMARY=garbage
  HARDEN_OUT="$(
    # shellcheck source=/dev/null
    source "$LOGGING_LIB"
    unset _REPOLENS_LOG_FILE _REPOLENS_LOG_LEVEL_NUM _REPOLENS_LOG_LEVEL_CACHE_KEY 2>/dev/null || true
    _dedupe_resolve_sim_threshold DEDUPE_TITLE_SIM_PRIMARY 8500 2>"$ERRFILE"
  )"
  HARDEN_ERR="$(cat "$ERRFILE")"
  unset DEDUPE_TITLE_SIM_PRIMARY
  TOTAL=$((TOTAL + 1))
  if [[ "$HARDEN_OUT" == "8500" ]]; then
    pass_with "uninitialized logging globals -> resolver still emits the default (8500)"
  else
    fail_with "uninitialized logging globals -> resolver still emits the default (8500)" "got '$HARDEN_OUT'"
  fi
  assert_not_contains "uninitialized logging globals -> resolver does not crash (no unbound variable)" \
    "unbound variable" "$HARDEN_ERR"
  assert_contains "uninitialized logging globals -> resolver still warns" \
    "WARN" "$HARDEN_ERR"
else
  echo "  (skip: lib/logging.sh not present at $LOGGING_LIB)"
fi

echo ""
echo "=== _dedupe_is_match: SECONDARY invalid input is hardened (independent read from primary) ==="

# The secondary threshold is resolved through the SAME validated resolver as the
# primary, but via a SEPARATE read (lib/dedupe.sh resolves DEDUPE_TITLE_SIM_SECONDARY
# on its own line). The invalid-input contract — fall back to the 6000 default,
# warn, never crash, never match-everything — must therefore hold for the secondary
# independently. None of the invalid-input cases above touch the secondary, so a
# regression that reverted ONLY the secondary read to the raw `${VAR:-6000}` form
# (which aborts under `set -u` on garbage and matches every same-location pair on a
# negative value) would slip past every existing assertion. These two pin it down.

# Same-location, sub-primary-similarity pair (Jaccard ~6666, below primary 8500):
# it can match ONLY via the secondary/location branch. A garbage secondary must
# resolve to the 6000 default -> the pair still MATCHES (6666 >= 6000), emits a
# WARN, and does NOT crash. The raw read `(( sim >= garbage ))` aborts the
# predicate under `set -u` ("unbound variable") — that is the regression guarded.
SEC_XA='{
  "domain":"authorization",
  "primary_location":"src/mtls.go:42",
  "title":"[high] mTLS accepts certificates with empty common name"
}'
SEC_XB='{
  "domain":"cryptography",
  "primary_location":"src/mtls.go:42:7",
  "title":"[critical] mTLS accepts certificates with empty common subject"
}'

export DEDUPE_TITLE_SIM_SECONDARY=garbage
run_match "$SEC_XA" "$SEC_XB"
SEC_BAD_ERR="$(cat "$ERRFILE")"
unset DEDUPE_TITLE_SIM_SECONDARY
assert_success "garbage secondary -> same-location sub-primary pair still matches (fallback to 6000)" "$DM_RC"
assert_not_contains "garbage secondary does not crash the predicate (no unbound variable)" \
  "unbound variable" "$SEC_BAD_ERR"
assert_contains "garbage secondary emits a WARN" "WARN" "$SEC_BAD_ERR"

# Negative secondary on a same-location but UNRELATED-title pair (near-zero title
# similarity). Pre-fix `(( sim >= -5 ))` is always true, so the secondary branch
# would collapse EVERY same-location pair. Post-fix the resolver falls back to
# 6000 -> near-zero similarity cannot clear the bar -> no match (match-everything
# guard, mirroring the primary negative case for the secondary read).
SEC_UNREL_A='{"domain":"authorization","primary_location":"src/app.go:10","title":"Hardcoded admin password in source"}'
SEC_UNREL_B='{"domain":"cryptography","primary_location":"src/app.go:10","title":"Deprecated TLS one point zero handshake"}'

export DEDUPE_TITLE_SIM_SECONDARY=-5
run_match "$SEC_UNREL_A" "$SEC_UNREL_B"
unset DEDUPE_TITLE_SIM_SECONDARY
assert_failure "negative secondary -> same-location unrelated pair does NOT match (no match-everything)" "$DM_RC"

echo ""
echo "=== validate_manifest: an invalid threshold warns ONCE, not per O(n^2) pair ==="

# The primary bar is resolved a SINGLE time before the pairwise loop, so an
# invalid override produces exactly one WARN regardless of manifest size. A
# regression that resolved inside the loop would warn once per pair (3 pairs for
# a 3-entry manifest) — a warn storm that scales O(n^2). Three pairwise-distinct
# titles keep every pair below the fallback 8500 bar, so validate succeeds and
# the only resolver warning present is the single fall-back notice.
TRIPLE="$TMPDIR/triple.json"
write_triple_manifest "$TRIPLE" \
  "Authn bypass via forged session cookie in the gateway" \
  "N plus one query slows the analytics dashboard export" \
  "Unbounded recursion in the markdown table renderer"

export DEDUPE_TITLE_SIM_PRIMARY=garbage
run_validate "$TRIPLE"
TRIPLE_ERR="$(cat "$ERRFILE")"
unset DEDUPE_TITLE_SIM_PRIMARY
assert_success "garbage threshold on a 3-entry distinct manifest still validates (fallback 8500)" "$VM_RC"
WARN_COUNT="$(grep -c 'Invalid DEDUPE_TITLE_SIM_PRIMARY' <<<"$TRIPLE_ERR" || true)"
TOTAL=$((TOTAL + 1))
if [[ "$WARN_COUNT" -eq 1 ]]; then
  pass_with "invalid threshold warns exactly once for a 3-entry manifest (resolved before the loop)"
else
  fail_with "invalid threshold warns exactly once for a 3-entry manifest (resolved before the loop)" \
    "expected 1 warning, got $WARN_COUNT"
fi

echo ""
echo "=== resolver delegate path: initialized RepoLens logging routes the WARN to the log file (stdout stays clean) ==="

# The PRODUCTION warn-routing path that the attempt-3 gate in
# _synthesize_log_min_severity_warn enables: when RepoLens logging is initialized
# (_REPOLENS_LOG_FILE set AND lib/logging.sh's own log_warn defined), the helper
# DELEGATES to log_warn — which appends the WARN to the log FILE (and stderr) —
# instead of taking the printf fallback. Every OTHER assertion in this file runs
# logging-UNINITIALIZED, so all of them exercise only the fallback branch; the
# delegate branch (the positive side of the `[[ -n $_REPOLENS_LOG_FILE ]]` gate,
# and the exact path a real `repolens.sh` run takes after init_logging) is
# otherwise untested. The two QG attempts turned entirely on this warn routing,
# so the healthy delegate path is worth pinning. Contract under test:
#   - the resolver's stdout is STILL exactly the default (the warning never leaks
#     onto the captured threshold value, even routed through log_warn),
#   - the WARN actually lands in the initialized log file,
#   - nothing crashes (no `unbound variable`).
# Run entirely inside a subshell with a private init_logging dir so the globals
# never leak into the parent and break the logging-uninitialized assumption above.
if [[ -f "$LOGGING_LIB" ]]; then
  DELEG_LOG_DIR="$TMPDIR/delegate-logs"
  export DEDUPE_TITLE_SIM_PRIMARY=garbage
  DELEGATE_OUT="$(
    # shellcheck source=/dev/null
    source "$LOGGING_LIB"
    # Pin the level so the WARN is emitted regardless of an ambient
    # REPOLENS_LOG_LEVEL (e.g. silent) in the runner's environment.
    export REPOLENS_LOG_LEVEL=info
    init_logging "deleg" "$DELEG_LOG_DIR"
    _dedupe_resolve_sim_threshold DEDUPE_TITLE_SIM_PRIMARY 8500 2>"$ERRFILE"
  )"
  DELEGATE_ERR="$(cat "$ERRFILE")"
  unset DEDUPE_TITLE_SIM_PRIMARY
  DELEG_LOG_CONTENT=""
  [[ -f "$DELEG_LOG_DIR/deleg.log" ]] && DELEG_LOG_CONTENT="$(cat "$DELEG_LOG_DIR/deleg.log")"

  TOTAL=$((TOTAL + 1))
  if [[ "$DELEGATE_OUT" == "8500" ]]; then
    pass_with "initialized logging -> resolver stdout is still exactly the default (8500)"
  else
    fail_with "initialized logging -> resolver stdout is still exactly the default (8500)" \
      "got '$DELEGATE_OUT'"
  fi
  assert_contains "initialized logging -> the WARN is routed to the log file" \
    "Invalid DEDUPE_TITLE_SIM_PRIMARY" "$DELEG_LOG_CONTENT"
  assert_contains "initialized logging -> log-file line carries the WARN severity" \
    "[WARN]" "$DELEG_LOG_CONTENT"
  assert_not_contains "initialized logging -> resolver does not crash (no unbound variable)" \
    "unbound variable" "$DELEGATE_ERR"
else
  echo "  (skip: lib/logging.sh not present at $LOGGING_LIB)"
fi

finish
