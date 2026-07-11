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

# Tests for issue #179: verification-gate regression test.
#
# Two gates must hold:
#
#   1. S3 (per-cluster filing): the filing callback re-verifies every
#      cited file:line citation before calling `gh issue create`. If any
#      citation does not match the on-disk code, the cluster MUST receive
#      a `.failed` sentinel beginning with `VERIFICATION_FAILED:` and the
#      forge create command MUST NOT run. Asserted via:
#        - `filing_verify_cluster_citations` (deterministic shell helper)
#        - `dispatch_filing_batch` with a citation-aware callback and a
#          PATH-shadowed `gh` stub that records every invocation.
#
#   2. B4 -> S2/S4 propagation: a finding the verifier marked `WRONG`
#      must not survive into `final/manifest.json`. Asserted via
#      `validate_manifest_against_verification` and `run_synthesizer`
#      using a stubbed `run_agent` that deliberately leaks a WRONG cluster.
#
# All test artifacts live under tests/logs/test-verification-gate/ so the
# repo stays clean. No real agent, forge, or network call is performed.

# shellcheck disable=SC2329 # Helpers are invoked indirectly by the test harness.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILING_LIB="$SCRIPT_DIR/lib/filing.sh"
SYNTHESIZE_LIB="$SCRIPT_DIR/lib/synthesize.sh"
PARALLEL_LIB="$SCRIPT_DIR/lib/parallel.sh"
LOGGING_LIB="$SCRIPT_DIR/lib/logging.sh"
TEMPLATE_LIB="$SCRIPT_DIR/lib/template.sh"
CORE_LIB="$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-verification-gate"
mkdir -p "$TMP_PARENT"
TMPDIR_REAL="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR_REAL"
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not find '$needle' in: ${haystack:0:300}"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpectedly found '$needle' in: ${haystack:0:300}"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -e "$path" ]]; then
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

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Library availability check --------------------------------------------
[[ -f "$FILING_LIB" ]]     || { echo "  FAIL: lib/filing.sh missing";     exit 1; }
[[ -f "$SYNTHESIZE_LIB" ]] || { echo "  FAIL: lib/synthesize.sh missing"; exit 1; }

# shellcheck disable=SC1090
source "$LOGGING_LIB"
# shellcheck disable=SC1090
source "$PARALLEL_LIB"
# shellcheck disable=SC1090
source "$TEMPLATE_LIB"
# shellcheck disable=SC1090
source "$CORE_LIB"
# shellcheck disable=SC1090
source "$FILING_LIB"
# shellcheck disable=SC1090
source "$SYNTHESIZE_LIB"

# --- Build fixture repo with known content ---------------------------------
PROJECT_PATH="$TMPDIR_REAL/project"
mkdir -p "$PROJECT_PATH/src"

cat > "$PROJECT_PATH/src/auth.sh" <<'EOF'
#!/usr/bin/env bash
# auth.sh — fixture for verification-gate test.

check_password() {
  local password="$1"
  if [[ -z "$password" ]]; then
    return 1
  fi
  return 0
}

login_handler() {
  local user="$1" pass="$2"
  check_password "$pass" || return 1
  echo "logged in: $user"
}
EOF

cat > "$PROJECT_PATH/src/config.sh" <<'EOF'
#!/usr/bin/env bash
# config.sh — fixture for verification-gate test.

DEFAULT_PORT=8080
DEFAULT_HOST="localhost"

load_config() {
  local file="$1"
  if [[ -f "$file" ]]; then
    source "$file"
  fi
}
EOF

# Sanity: confirm line counts match what the manifest asserts.
auth_lines=$(wc -l < "$PROJECT_PATH/src/auth.sh" | tr -d ' ')
config_lines=$(wc -l < "$PROJECT_PATH/src/config.sh" | tr -d ' ')
TOTAL=$((TOTAL + 1))
if (( auth_lines >= 14 && config_lines >= 9 )); then
  pass_with "fixture files have expected line counts (auth=$auth_lines, config=$config_lines)"
else
  fail_with "fixture file line counts unexpected" "auth=$auth_lines config=$config_lines"
fi

echo ""
echo "=== Case 1: filing_verify_cluster_citations — happy path ==="

ok_entry='{
  "cluster_id": "cluster-ok-1",
  "body": "## References\n- src/auth.sh:4 — `check_password()`\n- src/config.sh:4 — `DEFAULT_PORT=8080`\n"
}'
reason="$(filing_verify_cluster_citations "$PROJECT_PATH" "$ok_entry" 2>&1)"
rc=$?
assert_success "ok entry passes citation gate" "$rc"
assert_eq "ok entry produces no reason text" "" "$reason"

echo ""
echo "=== Case 2: filing_verify_cluster_citations — missing line ==="

phantom_missing_entry='{
  "cluster_id": "cluster-phantom-missing-line",
  "body": "Body references src/auth.sh:999 as the defective location."
}'
reason="$(filing_verify_cluster_citations "$PROJECT_PATH" "$phantom_missing_entry" 2>&1)"
rc=$?
assert_failure "missing-line citation fails gate" "$rc"
assert_contains "reason mentions line exceeds" "line exceeds file length" "$reason"
assert_contains "reason names offending file" "src/auth.sh:999" "$reason"

echo ""
echo "=== Case 3: filing_verify_cluster_citations — snippet mismatch ==="

phantom_mismatch_entry='{
  "cluster_id": "cluster-phantom-mismatch",
  "body": "Body cites src/auth.sh:4 with snippet `dangerous_eval` that does not exist in the file."
}'
reason="$(filing_verify_cluster_citations "$PROJECT_PATH" "$phantom_mismatch_entry" 2>&1)"
rc=$?
assert_failure "snippet-mismatch citation fails gate" "$rc"
assert_contains "reason mentions snippet" "snippet not found" "$reason"
assert_contains "reason names citation" "src/auth.sh:4" "$reason"

echo ""
echo "=== Case 4: filing_verify_cluster_citations — no citations at all ==="

no_cite_entry='{
  "cluster_id": "cluster-no-cite",
  "body": "Body has prose but no file colon line references at all."
}'
reason="$(filing_verify_cluster_citations "$PROJECT_PATH" "$no_cite_entry" 2>&1)"
rc=$?
assert_failure "body with zero citations fails gate" "$rc"
assert_contains "reason mentions no citations" "no citations" "$reason"

echo ""
echo "=== Case 5: end-to-end S3 — 5 clusters, 3 OK + 2 phantom ==="

RUN_LOG="$TMPDIR_REAL/run-s3"
mkdir -p "$RUN_LOG/final/filed"
export LOG_BASE="$RUN_LOG"

cat > "$RUN_LOG/final/manifest.json" <<'JSON'
[
  {
    "cluster_id": "cluster-ok-1",
    "title": "[medium] Validate login password input properly",
    "severity": "medium",
    "domain": "code",
    "lens": "input-validation",
    "root_cause_category": "missing-validation",
    "source_finding_paths": ["logs/run-s3/rounds/round-1/lens-outputs/code/input-validation.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "## Scope\nsrc/auth.sh:4 — `check_password()` lacks length and entropy checks.\n## References\n- src/auth.sh:4 — `check_password()`\n"
  },
  {
    "cluster_id": "cluster-ok-2",
    "title": "[low] Surface login handler errors clearly",
    "severity": "low",
    "domain": "code",
    "lens": "error-handling",
    "root_cause_category": "swallowed-error",
    "source_finding_paths": ["logs/run-s3/rounds/round-1/lens-outputs/code/error-handling.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "## Scope\nsrc/auth.sh:12 — `login_handler` echoes silently on failure.\n## References\n- src/auth.sh:12 — `login_handler()`\n"
  },
  {
    "cluster_id": "cluster-ok-3",
    "title": "[low] Document default config knobs",
    "severity": "low",
    "domain": "docs",
    "lens": "config-docs",
    "root_cause_category": "docs-drift",
    "source_finding_paths": ["logs/run-s3/rounds/round-1/lens-outputs/docs/config-docs.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["docs"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "## Scope\nsrc/config.sh:4 — `DEFAULT_PORT` is undocumented in README.\n## References\n- src/config.sh:4 — `DEFAULT_PORT=8080`\n"
  },
  {
    "cluster_id": "cluster-phantom-missing-line",
    "title": "[high] Patch alleged race condition at src/auth.sh:999",
    "severity": "high",
    "domain": "code",
    "lens": "concurrency",
    "root_cause_category": "race-condition",
    "source_finding_paths": ["logs/run-s3/rounds/round-1/lens-outputs/code/concurrency.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "## Scope\nAllegedly src/auth.sh:999 is racy.\n## References\n- src/auth.sh:999\n"
  },
  {
    "cluster_id": "cluster-phantom-mismatch",
    "title": "[critical] Remove dangerous_eval from src/config.sh",
    "severity": "critical",
    "domain": "code",
    "lens": "injection",
    "root_cause_category": "code-injection",
    "source_finding_paths": ["logs/run-s3/rounds/round-1/lens-outputs/code/injection.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug", "security"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "## Scope\nsrc/config.sh:4 — supposedly contains snippet `dangerous_eval $payload`.\n## References\n- src/config.sh:4 — `dangerous_eval $payload`\n"
  }
]
JSON

# Fake `gh`: PATH-shadowed stub that records each invocation to GH_LOG
# and emits a deterministic URL for `issue create`.
FAKE_BIN="$TMPDIR_REAL/fake-bin"
mkdir -p "$FAKE_BIN"
export GH_LOG="$TMPDIR_REAL/gh.log"
: > "$GH_LOG"
cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue create")
    echo "https://example.invalid/issues/fake-$RANDOM"
    exit 0
    ;;
  "issue list")
    echo "[]"
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$FAKE_BIN/gh"

export PATH="$FAKE_BIN:$PATH"

# Verification-aware filing callback. This is the executable contract that
# the S3 prompt instructs the agent to follow: re-verify citations against
# live code, and on mismatch never call `gh issue create` — write a
# `VERIFICATION_FAILED:` sentinel instead. By exercising
# filing_verify_cluster_citations directly, the test proves the actual gate
# logic, not just a hand-rolled decision table.
verifying_filing_callback() {
  local run_id="$1" cluster_id="$2"
  local log_base manifest filed_dir entry reason
  log_base="$(_filing_log_base "$run_id")"
  manifest="$log_base/final/manifest.json"
  filed_dir="$log_base/final/filed"
  entry="$(jq -c --arg cid "$cluster_id" '.[] | select(.cluster_id == $cid)' "$manifest")"

  if reason="$(filing_verify_cluster_citations "$PROJECT_PATH" "$entry" 2>&1)"; then
    # Verification passed — invoke the fake forge.
    local url body_file
    body_file="$filed_dir/$cluster_id.body.md"
    jq -r '.body' <<<"$entry" > "$body_file"
    url="$(gh issue create -R fake/repo --title "fake-title-$cluster_id" --body-file "$body_file")"
    printf '%s\n' "$url" > "$filed_dir/$cluster_id.url"
  else
    printf 'VERIFICATION_FAILED: %s\n' "$reason" > "$filed_dir/$cluster_id.failed"
  fi
  rm -f "$filed_dir/$cluster_id.lock"
  return 0
}

export _FILING_AGENT_CALLBACK="verifying_filing_callback"
output="$(dispatch_filing_batch "run-s3" 2>"$TMPDIR_REAL/run-s3.err")"
status=$?

assert_success "dispatcher returns 0" "$status"
assert_eq "aggregate counts: 3 filed, 2 verification-failed, 0 skipped" \
  "Filed: 3, Verification-failed: 2, Skipped-existing: 0" "$output"

# Sentinel files
assert_file_exists ".url for cluster-ok-1"  "$RUN_LOG/final/filed/cluster-ok-1.url"
assert_file_exists ".url for cluster-ok-2"  "$RUN_LOG/final/filed/cluster-ok-2.url"
assert_file_exists ".url for cluster-ok-3"  "$RUN_LOG/final/filed/cluster-ok-3.url"
assert_file_exists ".failed for cluster-phantom-missing-line" \
  "$RUN_LOG/final/filed/cluster-phantom-missing-line.failed"
assert_file_exists ".failed for cluster-phantom-mismatch" \
  "$RUN_LOG/final/filed/cluster-phantom-mismatch.failed"

# No cluster has BOTH .url and .failed
for cid in cluster-ok-1 cluster-ok-2 cluster-ok-3; do
  assert_file_missing ".failed must NOT exist for $cid" \
    "$RUN_LOG/final/filed/$cid.failed"
done
for cid in cluster-phantom-missing-line cluster-phantom-mismatch; do
  assert_file_missing ".url must NOT exist for $cid" \
    "$RUN_LOG/final/filed/$cid.url"
done

# Exact .url / .failed counts
url_count=$(find "$RUN_LOG/final/filed" -maxdepth 1 -name '*.url'    | wc -l | tr -d ' ')
failed_count=$(find "$RUN_LOG/final/filed" -maxdepth 1 -name '*.failed' | wc -l | tr -d ' ')
assert_eq "exactly 3 .url files" "3" "$url_count"
assert_eq "exactly 2 .failed files" "2" "$failed_count"

# Each .failed begins with VERIFICATION_FAILED: and has a non-empty reason
for cid in cluster-phantom-missing-line cluster-phantom-mismatch; do
  first_line="$(head -1 "$RUN_LOG/final/filed/$cid.failed")"
  assert_contains "$cid .failed begins with VERIFICATION_FAILED:" \
    "VERIFICATION_FAILED:" "$first_line"
  # Reason after the prefix must be non-empty
  reason="${first_line#VERIFICATION_FAILED: }"
  TOTAL=$((TOTAL + 1))
  if [[ -n "$reason" && "$reason" != "$first_line" ]]; then
    pass_with "$cid .failed reason is non-empty"
  else
    fail_with "$cid .failed reason is non-empty" "first line: '$first_line'"
  fi
done

# missing-line sentinel mentions the offending file:line
phantom_missing_line="$(head -1 "$RUN_LOG/final/filed/cluster-phantom-missing-line.failed")"
assert_contains "missing-line sentinel names src/auth.sh:999" \
  "src/auth.sh:999" "$phantom_missing_line"
assert_contains "missing-line sentinel mentions line exceeds" \
  "line exceeds" "$phantom_missing_line"

# mismatch sentinel mentions src/config.sh:4 and snippet
phantom_mismatch_line="$(head -1 "$RUN_LOG/final/filed/cluster-phantom-mismatch.failed")"
assert_contains "mismatch sentinel names src/config.sh:4" \
  "src/config.sh:4" "$phantom_mismatch_line"
assert_contains "mismatch sentinel mentions snippet" \
  "snippet" "$phantom_mismatch_line"

# `gh` log assertions: exactly three `issue create` calls.
gh_create_calls=$(grep -c '^issue create' "$GH_LOG" || true)
assert_eq "fake gh recorded exactly 3 issue-create calls" "3" "$gh_create_calls"

# Every issue-create call should reference one of the three OK clusters.
# We compare against the per-cluster fake-title-<cid> embedded in --title.
gh_log_text="$(cat "$GH_LOG")"
assert_contains "gh log contains fake-title-cluster-ok-1" \
  "fake-title-cluster-ok-1" "$gh_log_text"
assert_contains "gh log contains fake-title-cluster-ok-2" \
  "fake-title-cluster-ok-2" "$gh_log_text"
assert_contains "gh log contains fake-title-cluster-ok-3" \
  "fake-title-cluster-ok-3" "$gh_log_text"

# CRITICAL: no phantom cluster id is ever in an `issue create` invocation.
phantom_create_count=$(grep -c '^issue create.*cluster-phantom' "$GH_LOG" || true)
assert_eq "zero phantom clusters reached gh issue create" "0" "$phantom_create_count"
assert_not_contains "gh log has NO cluster-phantom-missing-line" \
  "cluster-phantom-missing-line" "$gh_log_text"
assert_not_contains "gh log has NO cluster-phantom-mismatch" \
  "cluster-phantom-mismatch" "$gh_log_text"

unset LOG_BASE
unset _FILING_AGENT_CALLBACK

echo ""
echo "=== Case 6: validate_manifest_against_verification — no leak passes ==="

VER_DIR="$TMPDIR_REAL/ver"
mkdir -p "$VER_DIR"

cat > "$VER_DIR/verification.json" <<'JSON'
[
  {"finding_id":"aaaaaaaaaaaaaaaa","status":"VERIFIED","notes":"ok","lens_id":"x","domain":"code","round":1,"source_finding_path":"logs/run-x/rounds/round-1/lens-outputs/code/x.md"},
  {"finding_id":"bbbbbbbbbbbbbbbb","status":"STALE","notes":"drift","lens_id":"y","domain":"code","round":1,"source_finding_path":"logs/run-x/rounds/round-1/lens-outputs/code/y.md"}
]
JSON

cat > "$VER_DIR/manifest-clean.json" <<'JSON'
[
  {
    "cluster_id": "cluster-clean",
    "title": "[low] Some clean issue",
    "severity": "low",
    "domain": "code",
    "lens": "x",
    "root_cause_category": "trivial",
    "source_finding_paths": ["logs/run-x/rounds/round-1/lens-outputs/code/x.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "verification_status": "verified",
    "body": "ok body"
  }
]
JSON

validate_manifest_against_verification "$VER_DIR/manifest-clean.json" "$VER_DIR/verification.json" 2>/dev/null
rc=$?
assert_success "no-wrong-leak manifest passes verifier propagation check" "$rc"

echo ""
echo "=== Case 7: validate_manifest_against_verification — WRONG leak rejected ==="

cat > "$VER_DIR/verification-with-wrong.json" <<'JSON'
[
  {"finding_id":"aaaaaaaaaaaaaaaa","status":"VERIFIED","notes":"ok","lens_id":"x","domain":"code","round":1,"source_finding_path":"logs/run-x/rounds/round-1/lens-outputs/code/x.md"},
  {"finding_id":"cccccccccccccccc","status":"WRONG","notes":"hallucinated","lens_id":"z","domain":"code","round":1,"source_finding_path":"logs/run-x/rounds/round-1/lens-outputs/code/z.md"}
]
JSON

cat > "$VER_DIR/manifest-leaky.json" <<'JSON'
[
  {
    "cluster_id": "cluster-clean",
    "title": "[low] Clean entry",
    "severity": "low",
    "domain": "code",
    "lens": "x",
    "root_cause_category": "trivial",
    "source_finding_paths": ["logs/run-x/rounds/round-1/lens-outputs/code/x.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "verification_status": "verified",
    "body": "ok body"
  },
  {
    "cluster_id": "cluster-hallucinated",
    "title": "[critical] Hallucinated finding leaked through",
    "severity": "critical",
    "domain": "code",
    "lens": "z",
    "root_cause_category": "phantom",
    "source_finding_paths": ["logs/run-x/rounds/round-1/lens-outputs/code/z.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "phantom body"
  }
]
JSON

leaky_err="$TMPDIR_REAL/leaky.err"
validate_manifest_against_verification "$VER_DIR/manifest-leaky.json" \
  "$VER_DIR/verification-with-wrong.json" 2>"$leaky_err"
rc=$?
assert_failure "WRONG-leaking manifest is rejected" "$rc"
err_text="$(cat "$leaky_err")"
assert_contains "stderr names offending cluster id" \
  "cluster-hallucinated" "$err_text"
assert_contains "stderr mentions WRONG" "WRONG" "$err_text"

echo ""
echo "=== Case 8: WRONG path with at least one non-WRONG finding is NOT pruned ==="
# When the verifier emits BOTH a WRONG and a VERIFIED entry for the SAME
# source_finding_path (one .md file holds multiple findings), the cluster
# remains legitimate — the verified finding still backs it.
cat > "$VER_DIR/verification-mixed.json" <<'JSON'
[
  {"finding_id":"aaaaaaaaaaaaaaaa","status":"VERIFIED","notes":"ok","lens_id":"x","domain":"code","round":1,"source_finding_path":"logs/run-x/rounds/round-1/lens-outputs/code/mixed.md"},
  {"finding_id":"dddddddddddddddd","status":"WRONG","notes":"hallucinated","lens_id":"x","domain":"code","round":1,"source_finding_path":"logs/run-x/rounds/round-1/lens-outputs/code/mixed.md"}
]
JSON

cat > "$VER_DIR/manifest-mixed.json" <<'JSON'
[
  {
    "cluster_id": "cluster-mixed",
    "title": "[low] Mixed but legitimate",
    "severity": "low",
    "domain": "code",
    "lens": "x",
    "root_cause_category": "mixed",
    "source_finding_paths": ["logs/run-x/rounds/round-1/lens-outputs/code/mixed.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "verification_status": "verified",
    "body": "ok body"
  }
]
JSON

validate_manifest_against_verification "$VER_DIR/manifest-mixed.json" \
  "$VER_DIR/verification-mixed.json" 2>/dev/null
rc=$?
assert_success "mixed-path cluster (one verified, one wrong) is accepted" "$rc"

echo ""
echo "=== Case 9: run_synthesizer rejects manifest that leaks a WRONG cluster ==="

RUN_LOG="$TMPDIR_REAL/run-leak"
mkdir -p "$RUN_LOG/rounds/round-1/lens-outputs/code"
mkdir -p "$RUN_LOG/final"
echo "finding x" > "$RUN_LOG/rounds/round-1/lens-outputs/code/x.md"
echo "finding z" > "$RUN_LOG/rounds/round-1/lens-outputs/code/z.md"

cat > "$RUN_LOG/final/verification.json" <<'JSON'
[
  {"finding_id":"aaaaaaaaaaaaaaaa","status":"VERIFIED","notes":"ok","lens_id":"x","domain":"code","round":1,"source_finding_path":"logs/run-leak/rounds/round-1/lens-outputs/code/x.md"},
  {"finding_id":"cccccccccccccccc","status":"WRONG","notes":"phantom","lens_id":"z","domain":"code","round":1,"source_finding_path":"logs/run-leak/rounds/round-1/lens-outputs/code/z.md"}
]
JSON

export LOG_BASE="$RUN_LOG"
export AGENT="claude"
export PROJECT_PATH

# Override compose_prompt and run_agent: stub the synthesizer to emit a
# manifest containing the WRONG-only cluster. The deterministic validator
# must reject it and the dispatcher must NOT promote a manifest.json.
compose_prompt() { printf 'STUB_PROMPT'; }
run_agent() {
  cat <<'OUT'
[
  {
    "cluster_id": "cluster-ok",
    "title": "[low] Legitimate finding",
    "severity": "low",
    "domain": "code",
    "lens": "x",
    "root_cause_category": "trivial",
    "source_finding_paths": ["logs/run-leak/rounds/round-1/lens-outputs/code/x.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "verification_status": "verified",
    "body": "ok"
  },
  {
    "cluster_id": "cluster-phantom",
    "title": "[critical] Phantom finding that should be filtered out",
    "severity": "critical",
    "domain": "code",
    "lens": "z",
    "root_cause_category": "phantom",
    "source_finding_paths": ["logs/run-leak/rounds/round-1/lens-outputs/code/z.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "phantom"
  }
]
DONE
OUT
}

run_synthesizer "run-leak" 2>"$TMPDIR_REAL/run-leak.err"
status=$?
assert_failure "run_synthesizer rejects manifest with leaked WRONG cluster" "$status"
assert_file_missing "no consumable manifest.json on WRONG-leak failure" \
  "$RUN_LOG/final/manifest.json"
leak_err="$(cat "$TMPDIR_REAL/run-leak.err")"
assert_contains "synthesizer error mentions cluster-phantom" \
  "cluster-phantom" "$leak_err"
assert_contains "synthesizer error mentions WRONG" "WRONG" "$leak_err"

echo ""
echo "=== Case 10: run_synthesizer accepts clean manifest with verification.json ==="

RUN_LOG="$TMPDIR_REAL/run-clean"
mkdir -p "$RUN_LOG/rounds/round-1/lens-outputs/code"
mkdir -p "$RUN_LOG/final"
echo "finding x" > "$RUN_LOG/rounds/round-1/lens-outputs/code/x.md"

cat > "$RUN_LOG/final/verification.json" <<'JSON'
[
  {"finding_id":"aaaaaaaaaaaaaaaa","status":"VERIFIED","notes":"ok","lens_id":"x","domain":"code","round":1,"source_finding_path":"logs/run-clean/rounds/round-1/lens-outputs/code/x.md"}
]
JSON

export LOG_BASE="$RUN_LOG"

run_agent() {
  cat <<'OUT'
[
  {
    "cluster_id": "cluster-ok-clean",
    "title": "[low] Plain clean cluster",
    "severity": "low",
    "domain": "code",
    "lens": "x",
    "root_cause_category": "trivial",
    "source_finding_paths": ["logs/run-clean/rounds/round-1/lens-outputs/code/x.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["bug"],
    "cross_link_actions": [],
    "granularity": "independent",
    "verification_status": "verified",
    "body": "clean"
  }
]
DONE
OUT
}

run_synthesizer "run-clean" 2>"$TMPDIR_REAL/run-clean.err"
status=$?
assert_success "run_synthesizer accepts clean manifest with verification.json" "$status"
assert_file_exists "manifest.json promoted on success" "$RUN_LOG/final/manifest.json"

unset LOG_BASE

finish
