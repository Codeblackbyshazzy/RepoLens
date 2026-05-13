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

# Tests for issue #186 - coordinated label bootstrap.
#
# Behavioral contract:
#   - lib/forge.sh exports forge_label_list_names <owner/repo>.
#   - The gh branch lists labels with one forge call, parses JSON label names,
#     and exposes failures as non-zero + empty stdout so callers can fall back.
#   - lib/forge.sh exports forge_label_bootstrap <owner/repo> <label-set-file>.
#   - The label-set file is newline-delimited label=color pairs.
#   - forge_label_bootstrap lists existing labels, creates only missing labels,
#     and falls back to creating the full desired set if listing fails.
#   - Repeated/concurrent bootstraps for the same repo, provider, and desired
#     label set share a cache/lock so a second fresh run is a near no-op.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

assert_rc_zero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected rc=0, got rc=$actual)"
  fi
}

assert_rc_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected non-zero rc, got 0)"
  fi
}

assert_function_exists() {
  local fn="$1"
  TOTAL=$((TOTAL + 1))
  if declare -F "$fn" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  PASS: $fn is exported"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $fn is not exported"
  fi
}

echo ""
echo "=== Test Suite: coordinated label bootstrap (issue #186) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/core.sh" ]] || { echo "FAIL: lib/core.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/forge.sh"

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_GH_LOG:-/dev/null}"

if [[ "$1 $2" == "label list" ]]; then
  if [[ -n "${REPOLENS_FAKE_LABEL_LIST_SLEEP:-}" ]]; then
    sleep "$REPOLENS_FAKE_LABEL_LIST_SLEEP"
  fi
  if [[ -n "${REPOLENS_FAKE_LABEL_LIST_STDERR+x}" ]]; then
    printf '%s\n' "$REPOLENS_FAKE_LABEL_LIST_STDERR" >&2
  fi
  if [[ -n "${REPOLENS_FAKE_LABEL_LIST_STDOUT+x}" ]]; then
    printf '%s\n' "$REPOLENS_FAKE_LABEL_LIST_STDOUT"
  fi
  exit "${REPOLENS_FAKE_LABEL_LIST_RC:-0}"
fi

if [[ "$1 $2" == "label create" ]]; then
  exit "${REPOLENS_FAKE_LABEL_CREATE_RC:-0}"
fi

exit 99
SH
chmod +x "$FAKE_BIN/gh"

export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
export FORGE_PROVIDER=gh
export REPOLENS_LABEL_CACHE_DIR="$TMPDIR/cache"
export REPOLENS_LABEL_CACHE_TTL=600

desired_file="$TMPDIR/desired-labels.txt"
cat > "$desired_file" <<'EOF'
audit:security/injection=ff5555
audit:code-quality/naming=ededed
spec:payments-flow=c9b1ff
EOF

desired_file_with_extra="$TMPDIR/desired-labels-with-extra.txt"
cat > "$desired_file_with_extra" <<'EOF'
audit:security/injection=ff5555
audit:code-quality/naming=ededed
spec:payments-flow=c9b1ff
audit:runtime/logging=8dd6f9
EOF

reset_fakes() {
  : > "$TMPDIR/gh.log"
  export REPOLENS_FAKE_GH_LOG="$TMPDIR/gh.log"
  unset REPOLENS_FAKE_LABEL_LIST_RC REPOLENS_FAKE_LABEL_LIST_STDOUT
  unset REPOLENS_FAKE_LABEL_LIST_STDERR REPOLENS_FAKE_LABEL_LIST_SLEEP
  unset REPOLENS_FAKE_LABEL_CREATE_RC
  rm -rf "$REPOLENS_LABEL_CACHE_DIR"
  mkdir -p "$REPOLENS_LABEL_CACHE_DIR"
}

run_forge_call() {
  local fn="$1"; shift
  (
    set -uo pipefail
    export PATH FORGE_PROVIDER REPOLENS_LABEL_CACHE_DIR REPOLENS_LABEL_CACHE_TTL
    [[ -n "${REPOLENS_FAKE_GH_LOG+x}" ]] && export REPOLENS_FAKE_GH_LOG
    [[ -n "${REPOLENS_FAKE_LABEL_LIST_RC+x}" ]] && export REPOLENS_FAKE_LABEL_LIST_RC
    [[ -n "${REPOLENS_FAKE_LABEL_LIST_STDOUT+x}" ]] && export REPOLENS_FAKE_LABEL_LIST_STDOUT
    [[ -n "${REPOLENS_FAKE_LABEL_LIST_STDERR+x}" ]] && export REPOLENS_FAKE_LABEL_LIST_STDERR
    [[ -n "${REPOLENS_FAKE_LABEL_LIST_SLEEP+x}" ]] && export REPOLENS_FAKE_LABEL_LIST_SLEEP
    [[ -n "${REPOLENS_FAKE_LABEL_CREATE_RC+x}" ]] && export REPOLENS_FAKE_LABEL_CREATE_RC
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    "$fn" "$@"
  )
}

echo "--- Group 1: exported public helpers ---"
echo ""
assert_function_exists forge_label_list_names
assert_function_exists forge_label_bootstrap

if ! declare -F forge_label_list_names >/dev/null 2>&1 || ! declare -F forge_label_bootstrap >/dev/null 2>&1; then
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  exit 1
fi

echo ""
echo "--- Group 2: gh label listing contract ---"
echo ""

echo "Test 1: forge_label_list_names parses gh label names and uses one list call"
reset_fakes
REPOLENS_FAKE_LABEL_LIST_STDOUT='[{"name":"audit:security/injection"},{"name":"enhancement"}]'
out="$(run_forge_call forge_label_list_names owner/repo 2>/dev/null)"
rc=$?
assert_rc_zero "label list succeeds" "$rc"
assert_eq "label names are printed one per line" $'audit:security/injection\nenhancement' "$out"
assert_eq "gh label list argv" "label list -R owner/repo --limit 1000 --json name" "$(cat "$TMPDIR/gh.log")"

echo ""
echo "Test 2: forge_label_list_names exposes gh failure for fallback callers"
reset_fakes
REPOLENS_FAKE_LABEL_LIST_RC=17
REPOLENS_FAKE_LABEL_LIST_STDERR='gh: temporary API failure'
out="$(run_forge_call forge_label_list_names owner/repo 2>/dev/null)"
rc=$?
assert_eq "stdout is empty on label-list failure" "" "$out"
assert_rc_nonzero "label-list failure returns non-zero" "$rc"

echo ""
echo "Test 2b: invalid gh label JSON triggers the create-all fallback path"
reset_fakes
REPOLENS_FAKE_LABEL_LIST_STDOUT='not json'
out="$(run_forge_call forge_label_bootstrap owner/repo "$desired_file" 2>/dev/null)"
rc=$?
assert_rc_zero "bootstrap succeeds after invalid label-list JSON" "$rc"
assert_eq "bootstrap emits no stdout after invalid label-list JSON" "" "$out"
expected_log=$'label list -R owner/repo --limit 1000 --json name\nlabel create audit:security/injection --color ff5555 --force -R owner/repo\nlabel create audit:code-quality/naming --color ededed --force -R owner/repo\nlabel create spec:payments-flow --color c9b1ff --force -R owner/repo'
assert_eq "invalid label-list JSON falls back to creating every desired label" "$expected_log" "$(cat "$TMPDIR/gh.log")"

echo ""
echo "--- Group 3: detect-then-create bootstrap ---"
echo ""

echo "Test 3: bootstrap creates only labels missing from the forge"
reset_fakes
REPOLENS_FAKE_LABEL_LIST_STDOUT='[{"name":"audit:security/injection"}]'
out="$(run_forge_call forge_label_bootstrap owner/repo "$desired_file" 2>/dev/null)"
rc=$?
assert_rc_zero "bootstrap succeeds" "$rc"
assert_eq "bootstrap emits no stdout" "" "$out"
expected_log=$'label list -R owner/repo --limit 1000 --json name\nlabel create audit:code-quality/naming --color ededed --force -R owner/repo\nlabel create spec:payments-flow --color c9b1ff --force -R owner/repo'
assert_eq "only missing labels are created" "$expected_log" "$(cat "$TMPDIR/gh.log")"

echo ""
echo "Test 4: bootstrap falls back to best-effort create-all when listing fails"
reset_fakes
REPOLENS_FAKE_LABEL_LIST_RC=18
REPOLENS_FAKE_LABEL_LIST_STDERR='gh: labels endpoint unavailable'
out="$(run_forge_call forge_label_bootstrap owner/repo "$desired_file" 2>/dev/null)"
rc=$?
assert_rc_zero "bootstrap remains best-effort on list failure" "$rc"
assert_eq "bootstrap emits no stdout after list failure" "" "$out"
expected_log=$'label list -R owner/repo --limit 1000 --json name\nlabel create audit:security/injection --color ff5555 --force -R owner/repo\nlabel create audit:code-quality/naming --color ededed --force -R owner/repo\nlabel create spec:payments-flow --color c9b1ff --force -R owner/repo'
assert_eq "list failure falls back to creating every desired label" "$expected_log" "$(cat "$TMPDIR/gh.log")"

echo ""
echo "--- Group 4: shared cache/lock coordination ---"
echo ""

echo "Test 5: concurrent bootstraps for one repo and label set do one create pass"
reset_fakes
REPOLENS_FAKE_LABEL_LIST_STDOUT='[]'
REPOLENS_FAKE_LABEL_LIST_SLEEP=0.2
run_forge_call forge_label_bootstrap owner/repo "$desired_file" >/dev/null 2>&1 &
pid1=$!
run_forge_call forge_label_bootstrap owner/repo "$desired_file" >/dev/null 2>&1 &
pid2=$!
wait "$pid1"; rc1=$?
wait "$pid2"; rc2=$?
assert_rc_zero "first concurrent bootstrap succeeds" "$rc1"
assert_rc_zero "second concurrent bootstrap succeeds" "$rc2"
label_list_count="$(grep -c '^label list ' "$TMPDIR/gh.log" 2>/dev/null || true)"
label_create_count="$(grep -c '^label create ' "$TMPDIR/gh.log" 2>/dev/null || true)"
assert_eq "concurrent bootstraps share one label-list call" "1" "$label_list_count"
assert_eq "concurrent bootstraps create each desired label once" "3" "$label_create_count"

echo ""
echo "Test 6: cache sentinel is keyed by the desired label set"
reset_fakes
REPOLENS_FAKE_LABEL_LIST_STDOUT='[]'
run_forge_call forge_label_bootstrap owner/repo "$desired_file" >/dev/null 2>&1
rc1=$?
run_forge_call forge_label_bootstrap owner/repo "$desired_file_with_extra" >/dev/null 2>&1
rc2=$?
assert_rc_zero "first label-set bootstrap succeeds" "$rc1"
assert_rc_zero "changed label-set bootstrap succeeds" "$rc2"
label_list_count="$(grep -c '^label list ' "$TMPDIR/gh.log" 2>/dev/null || true)"
label_create_count="$(grep -c '^label create ' "$TMPDIR/gh.log" 2>/dev/null || true)"
assert_eq "changed label set performs a second label-list call" "2" "$label_list_count"
assert_eq "changed label set creates its full desired set" "7" "$label_create_count"

echo ""
echo "Test 7: REPOLENS_LABEL_CACHE_TTL=0 disables fresh-sentinel skips"
reset_fakes
REPOLENS_FAKE_LABEL_LIST_STDOUT='[]'
REPOLENS_LABEL_CACHE_TTL=0
run_forge_call forge_label_bootstrap owner/repo "$desired_file" >/dev/null 2>&1
rc1=$?
run_forge_call forge_label_bootstrap owner/repo "$desired_file" >/dev/null 2>&1
rc2=$?
REPOLENS_LABEL_CACHE_TTL=600
assert_rc_zero "first ttl-zero bootstrap succeeds" "$rc1"
assert_rc_zero "second ttl-zero bootstrap succeeds" "$rc2"
label_list_count="$(grep -c '^label list ' "$TMPDIR/gh.log" 2>/dev/null || true)"
label_create_count="$(grep -c '^label create ' "$TMPDIR/gh.log" 2>/dev/null || true)"
assert_eq "ttl zero performs label-list work on each run" "2" "$label_list_count"
assert_eq "ttl zero repeats best-effort missing-label creation" "6" "$label_create_count"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
