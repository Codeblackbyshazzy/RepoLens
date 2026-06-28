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

# Behavioral contract for the type-resolution helpers (issue #344).
#
# Two pure helpers are added to lib/core.sh, next to finding_type_normalize:
#
#   domain_default_finding_type <domain>
#     Back-compat fallback. Maps a finding's domain (config/domains.json id) to a
#     sensible default canonical finding-type. Documented mappings (issue body):
#       security, llm-security                       -> security-vulnerability
#       testing                                      -> test-gap
#       performance                                  -> performance-risk
#       error-handling, concurrency, database        -> reliability-bug
#       code-quality, maintainability, architecture,
#         documentation, i18n                        -> maintainability
#       everything else / empty / no-arg             -> maintainability (default)
#     ALWAYS prints exactly one of the six canonical ids — never empty.
#
#   finding_resolve_type <file>
#     Canonical type for a finding markdown file: an explicit, valid `type:` in
#     the leading frontmatter wins (run through finding_type_normalize, so short
#     aliases like `perf` are repaired); a missing or unrecognized `type:` falls
#     back to domain_default_finding_type(domain:). ALWAYS prints exactly one of
#     the six canonical ids — never empty (AC: "registry records are always
#     typed"). set -u safe with a missing arg / missing file.
#
# These mirror the test_finding_type_normalize.sh style: source lib/core.sh and
# drive assert_eq cases through the pure helpers. NO real model is ever invoked.
# The frontmatter fixtures use the same --local finding format the ledger
# builders consume (see tests/test_ledger_from_local.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-finding-resolve-type"
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
    fail_with "$desc" "function '$fn' is not defined after sourcing lib/core.sh"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# write_finding <path> <domain> [type]
#   Writes a minimal but realistic --local finding markdown file with a leading
#   YAML frontmatter block. Pass an empty <domain> to omit the `domain:` key, and
#   omit (or pass empty) <type> to leave the `type:` key out entirely. The body
#   carries decoy `type:`/`domain:` lines to prove the resolver reads ONLY the
#   leading frontmatter block, never the markdown body.
write_finding() {
  local path="$1" domain="${2:-}" type="${3:-}"
  {
    printf '%s\n' '---'
    printf 'title: "[high] Synthetic finding for resolve-type tests"\n'
    printf 'severity: high\n'
    [[ -n "$domain" ]] && printf 'domain: %s\n' "$domain"
    printf 'lens: synthetic\n'
    [[ -n "$type" ]] && printf 'type: %s\n' "$type"
    printf '%s\n' '---'
    printf '%s\n' 'Body line with a decoy type: SHOULD_NOT_WIN and domain: SHOULD_NOT_WIN.'
  } > "$path"
}

if [[ ! -f "$CORE_LIB" ]]; then
  fail_with "lib/core.sh exists" "Missing $CORE_LIB"
  finish
fi

# shellcheck disable=SC1090
source "$CORE_LIB"

echo "=== helpers are defined after sourcing lib/core.sh ==="
assert_defined "domain_default_finding_type is defined" "domain_default_finding_type"
assert_defined "finding_resolve_type is defined" "finding_resolve_type"

echo "=== domain_default_finding_type: documented mappings ==="
# Grounded in config/domains.json ids + the issue body's mapping table.
assert_eq "security -> security-vulnerability" \
  "security-vulnerability" "$(domain_default_finding_type "security")"
assert_eq "llm-security -> security-vulnerability" \
  "security-vulnerability" "$(domain_default_finding_type "llm-security")"
assert_eq "testing -> test-gap" \
  "test-gap" "$(domain_default_finding_type "testing")"
assert_eq "performance -> performance-risk" \
  "performance-risk" "$(domain_default_finding_type "performance")"
assert_eq "error-handling -> reliability-bug" \
  "reliability-bug" "$(domain_default_finding_type "error-handling")"
assert_eq "concurrency -> reliability-bug" \
  "reliability-bug" "$(domain_default_finding_type "concurrency")"
assert_eq "database -> reliability-bug" \
  "reliability-bug" "$(domain_default_finding_type "database")"
assert_eq "code-quality -> maintainability" \
  "maintainability" "$(domain_default_finding_type "code-quality")"
assert_eq "maintainability -> maintainability" \
  "maintainability" "$(domain_default_finding_type "maintainability")"
assert_eq "architecture -> maintainability" \
  "maintainability" "$(domain_default_finding_type "architecture")"
assert_eq "documentation -> maintainability" \
  "maintainability" "$(domain_default_finding_type "documentation")"
assert_eq "i18n -> maintainability" \
  "maintainability" "$(domain_default_finding_type "i18n")"

echo "=== domain_default_finding_type: default + empty/no-arg safety ==="
# A real config/domains.json domain that is NOT in the explicit map falls through
# to the safe maintainability default (the intended behavior, not a gap).
assert_eq "frontend (real domain, unmapped) -> maintainability default" \
  "maintainability" "$(domain_default_finding_type "frontend")"
assert_eq "wholly-unknown domain -> maintainability default" \
  "maintainability" "$(domain_default_finding_type "totally-not-a-domain")"
# Empty / no-arg must not error under set -u and must still return a canonical id.
assert_eq "empty domain -> maintainability (never empty)" \
  "maintainability" "$(domain_default_finding_type "")"
assert_eq "no-arg -> maintainability (set -u safe, never empty)" \
  "maintainability" "$(domain_default_finding_type)"

echo "=== finding_resolve_type: (a) explicit valid type wins over domain ==="
# type: present and valid -> it wins, even when the domain default would differ.
f_explicit="$TMPDIR/a-explicit.md"
write_finding "$f_explicit" "testing" "security-vulnerability"
assert_eq "explicit valid type beats the domain default (testing would be test-gap)" \
  "security-vulnerability" "$(finding_resolve_type "$f_explicit")"

# A short alias in type: is repaired by finding_type_normalize and still wins.
f_alias="$TMPDIR/a-alias.md"
write_finding "$f_alias" "documentation" "perf"
assert_eq "explicit short-alias type repaired to performance-risk (beats maintainability)" \
  "performance-risk" "$(finding_resolve_type "$f_alias")"

echo "=== finding_resolve_type: (b) explicit INVALID type -> domain fallback ==="
# An unrecognized type: normalizes to empty, so resolution falls back to domain.
f_invalid="$TMPDIR/b-invalid.md"
write_finding "$f_invalid" "security" "not-a-real-type"
assert_eq "invalid type: falls back to the domain default (security -> security-vulnerability)" \
  "security-vulnerability" "$(finding_resolve_type "$f_invalid")"

echo "=== finding_resolve_type: (c) missing type -> domain fallback ==="
f_missing="$TMPDIR/c-missing.md"
write_finding "$f_missing" "performance"
assert_eq "missing type: falls back to the domain default (performance -> performance-risk)" \
  "performance-risk" "$(finding_resolve_type "$f_missing")"

echo "=== finding_resolve_type: (d) unknown domain -> maintainability ==="
f_unknown="$TMPDIR/d-unknown.md"
write_finding "$f_unknown" "totally-not-a-domain"
assert_eq "missing type + unknown domain -> maintainability" \
  "maintainability" "$(finding_resolve_type "$f_unknown")"

echo "=== finding_resolve_type: never empty (AC: records always typed) ==="
# Neither type: nor domain: present -> still resolves to a canonical id.
f_bare="$TMPDIR/e-bare.md"
write_finding "$f_bare" "" ""
assert_eq "no type: and no domain: -> maintainability (never empty)" \
  "maintainability" "$(finding_resolve_type "$f_bare")"
# Missing file / no-arg must be set -u safe and still print a canonical id.
assert_eq "no-arg -> maintainability (set -u safe, never empty)" \
  "maintainability" "$(finding_resolve_type)"

echo "=== finding_resolve_type: malformed / no-frontmatter inputs (reader edge cases) ==="
# The new lib/core.sh frontmatter reader (_finding_frontmatter_scalar) bails when
# the first line is not '---' and on an empty file. Every fixture above carries a
# well-formed leading '---' block, so these distinct reader branches are otherwise
# unexercised. Both must yield the maintainability default (never empty).
f_nofm="$TMPDIR/f-no-frontmatter.md"
{
  printf '%s\n' 'Just a plain markdown finding with no leading frontmatter block.'
  printf '%s\n' 'type: security-vulnerability'   # body lines, NOT frontmatter
  printf '%s\n' 'domain: security'
} > "$f_nofm"
assert_eq "file without a leading '---' block -> maintainability (reader bails, body ignored)" \
  "maintainability" "$(finding_resolve_type "$f_nofm")"

f_empty="$TMPDIR/g-empty.md"
: > "$f_empty"
assert_eq "empty file -> maintainability (never empty)" \
  "maintainability" "$(finding_resolve_type "$f_empty")"

echo "=== finding_resolve_type: quoted frontmatter values are de-quoted ==="
# Real YAML frontmatter may quote scalar values. The reader strips surrounding
# single/double quotes before normalize/domain-lookup; without that, a quoted
# type: would fail to normalize and a quoted domain: would miss the map. The
# fixtures above use only bare type:/domain: values, so the de-quote path is
# untested. Double-quoted type: must still win; single-quoted domain: must still
# drive the default.
f_qtype="$TMPDIR/h-quoted-type.md"
{
  printf '%s\n' '---'
  printf '%s\n' 'title: "[high] Quoted type value"'
  printf '%s\n' 'domain: testing'          # domain default (test-gap) must be overridden
  printf '%s\n' 'type: "performance-risk"' # double-quoted long id
  printf '%s\n' '---'
  printf '%s\n' 'body'
} > "$f_qtype"
assert_eq "double-quoted type: is de-quoted and wins over the domain default" \
  "performance-risk" "$(finding_resolve_type "$f_qtype")"

f_qdom="$TMPDIR/i-quoted-domain.md"
{
  printf '%s\n' '---'
  printf '%s\n' 'title: "[high] Quoted domain value, no type"'
  printf '%s\n' "domain: 'database'"        # single-quoted, no explicit type:
  printf '%s\n' '---'
  printf '%s\n' 'body'
} > "$f_qdom"
assert_eq "single-quoted domain: is de-quoted and drives the default (database -> reliability-bug)" \
  "reliability-bug" "$(finding_resolve_type "$f_qdom")"

finish
