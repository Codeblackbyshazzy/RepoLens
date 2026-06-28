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

# Tests for issue #345 — the proof-anchor strength validator (lib/validation.sh).
#
# `validate_proof_anchors <validation_json> [<project_path>]` reads the
# `proof_anchors` array out of the structured `validation` object that
# `parse_validation_block` (#332) emits and prints ONE normalized strength
# verdict on stdout, mirroring the house pattern
# `lib/verify.sh::validate_verification_manifest` (jq-driven, specifics to
# stderr, non-zero on failure):
#
#   solid — >=1 anchor is a well-formed `path:line` reference OR a substantive
#           verbatim code quote (length threshold + code-ish chars).
#   weak  — >=1 non-empty anchor, but every one is vague prose.
#   none  — no usable anchors (missing / null / non-array / empty array).
#
# Per-anchor rejection reasons go to STDERR; the single verdict token goes to
# STDOUT. The function is pure and sourceable: it reads its JSON-string argument
# plus jq alone, treats every anchor value as DATA (never eval'd), and writes no
# files. The optional second argument only READS the filesystem (best-effort
# containment check) and must never break a bare-fixture call.
#
# These are BEHAVIORAL tests against the public contract from the issue's
# acceptance criteria — they do not assume internal helper names, constant names,
# or the exact length threshold. Code-quote fixtures are chosen with wide margin
# (length >> any reasonable threshold, several code-ish chars) and prose fixtures
# carry zero code-ish chars, so the solid/weak split holds for any sane tuning.
# No real AI models are invoked; this is a pure jq-driven function.
#
# Group 10 additionally locks acceptance criterion 4 — the #334 classifier
# (`classify_validation_status`) must CONSUME this verdict rather than
# re-deriving anchor strength from array length. The observable consequence: a
# finding whose anchors are all vague prose, paired with a runnable local
# command, was previously `new` (length >= 1 == "solid") and must become
# `needs-validation` after the refactor.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATION_LIB="$SCRIPT_DIR/lib/validation.sh"

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

# Assert two values differ (used for "not solid" / "non-zero rc" invariants).
assert_ne() {
  local desc="$1" forbidden="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$forbidden" != "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Value must NOT equal '$forbidden', but it did"
  fi
}

# Assert a verdict is one of the three legal strength tokens — and, by
# construction, never a typo or empty string.
assert_member() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  case "$actual" in
    solid | weak | none)
      pass_with "$desc"
      ;;
    *)
      fail_with "$desc" "Got '$actual' — not a legal strength verdict (must be solid/weak/none)"
      ;;
  esac
}

assert_nonempty() {
  local desc="$1" value="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -n "$value" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-empty, got empty"
  fi
}

# Assert haystack contains needle as a literal substring.
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected to find '$needle' in: $haystack"
  fi
}

# Assert haystack does NOT contain needle as a literal substring.
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    fail_with "$desc" "Did NOT expect '$needle' in: $haystack"
  else
    pass_with "$desc"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS/$TOTAL passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

# Convenience: print just the stdout verdict (trailing newline stripped by $(...)).
verdict() {
  validate_proof_anchors "$1" 2>/dev/null
}

# Run the validator capturing stdout, stderr, and rc separately. Results land in
# the globals VA_OUT / VA_ERR / VA_RC. Optional 2nd arg is the project path.
VA_OUT=""
VA_ERR=""
VA_RC=0
run_va() {
  local json="$1" proj="${2:-}" errfile
  errfile="$(mktemp)"
  if [[ -n "$proj" ]]; then
    VA_OUT="$(validate_proof_anchors "$json" "$proj" 2>"$errfile")"
  else
    VA_OUT="$(validate_proof_anchors "$json" 2>"$errfile")"
  fi
  VA_RC=$?
  VA_ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

echo ""
echo "=== Test Suite: proof-anchor strength validator (issue #345) ==="
echo ""

# Red-phase guard: if the module does not exist yet, fail cleanly and stop.
if [[ ! -f "$VALIDATION_LIB" ]]; then
  fail_with "lib/validation.sh exists" "Missing $VALIDATION_LIB (not yet implemented)"
  finish
fi

echo "--- Group 1: sourceable module, validator defined, no side effects ---"
# Sourcing must define functions / constants only — no output, no work at source
# time (a top-level threshold constant assignment is silent, so this still holds).
# shellcheck disable=SC1090
source_out="$(source "$VALIDATION_LIB" 2>&1)"
assert_eq "sourcing lib/validation.sh emits nothing" "" "$source_out"

# shellcheck disable=SC1090
source "$VALIDATION_LIB"
TOTAL=$((TOTAL + 1))
if declare -F validate_proof_anchors >/dev/null 2>&1; then
  pass_with "validate_proof_anchors is defined after sourcing"
else
  fail_with "validate_proof_anchors is defined after sourcing"
  # Nothing else can be tested without the function — stop here (clean red phase).
  finish
fi

echo ""
echo "--- Group 2: the three required AC cases ---"
# 1. a `path:line` anchor -> solid (issue Tests bullet #1; fixture from the issue).
assert_eq "path:line anchor (lib/template.sh:208) -> solid" \
  "solid" \
  "$(verdict '{"proof_anchors":["lib/template.sh:208"]}')"
# 2. only vague prose -> weak (issue Tests bullet #2).
assert_eq "prose-only anchor (\"see the auth code\") -> weak" \
  "weak" \
  "$(verdict '{"proof_anchors":["see the auth code"]}')"
# 3. empty array -> none (issue Tests bullet #3).
assert_eq "empty proof_anchors array -> none" \
  "none" \
  "$(verdict '{"proof_anchors":[]}')"

echo ""
echo "--- Group 3: well-formed anchors -> solid (path:line OR substantive code quote) ---"
# Various path:line shapes all read as solid.
assert_eq "app.py:42 (path:line) -> solid" \
  "solid" \
  "$(verdict '{"proof_anchors":["app.py:42"]}')"
assert_eq "lib/x.sh:5 (nested path:line) -> solid" \
  "solid" \
  "$(verdict '{"proof_anchors":["lib/x.sh:5"]}')"
assert_eq "a:1 (minimal path:line) -> solid" \
  "solid" \
  "$(verdict '{"proof_anchors":["a:1"]}')"
# Substantive verbatim code quotes (long, several code-ish chars, no path:line
# shape) read as solid even without a file:line reference.
assert_eq "code quote 'subprocess.run([cmd], shell=True)' -> solid" \
  "solid" \
  "$(verdict '{"proof_anchors":["subprocess.run([cmd], shell=True)"]}')"
assert_eq "code quote 'if (user.role == \"admin\") { grant(); }' -> solid" \
  "solid" \
  "$(verdict '{"proof_anchors":["if (user.role == \"admin\") { grant(); }"]}')"

echo ""
echo "--- Group 4: vague prose-only anchors -> weak ---"
# Non-empty anchors that carry no path:line shape and no code-ish structure.
assert_eq "'see the auth handler' -> weak" \
  "weak" \
  "$(verdict '{"proof_anchors":["see the auth handler"]}')"
assert_eq "'look at the login function' -> weak" \
  "weak" \
  "$(verdict '{"proof_anchors":["look at the login function"]}')"
# Several anchors, all vague prose -> still weak (no single one is well-formed).
assert_eq "multiple prose anchors, none well-formed -> weak" \
  "weak" \
  "$(verdict '{"proof_anchors":["see the auth code","the validation is wrong","check the handler"]}')"

echo ""
echo "--- Group 5: no usable anchors -> none ---"
# Missing key (exactly what the parser emits for a finding with no anchors line).
assert_eq "missing proof_anchors key ({}) -> none" \
  "none" \
  "$(verdict '{}')"
# Explicit null must degrade to none rather than erroring under pipefail.
assert_eq "null proof_anchors -> none" \
  "none" \
  "$(verdict '{"proof_anchors":null}')"
# A legacy/foreign singular string (non-array) is not the plural array contract;
# defensively it carries no usable anchors -> none, and is never solid.
assert_member "non-array proof_anchors yields a legal verdict" \
  "$(verdict '{"proof_anchors":"app.py:1"}')"
assert_ne "non-array proof_anchors is never solid" \
  "solid" \
  "$(verdict '{"proof_anchors":"app.py:1"}')"
# A whitespace-only anchor has no usable content -> never solid (whether the
# implementation trims it to none or treats it as weak, it must not pass as solid).
assert_ne "whitespace-only anchor is never solid" \
  "solid" \
  "$(verdict '{"proof_anchors":["   "]}')"

echo ""
echo "--- Group 6: one well-formed anchor among prose -> solid (>=1 wins) ---"
# A single real reference makes the whole set solid even if other anchors are vague.
assert_eq "prose + one path:line anchor -> solid" \
  "solid" \
  "$(verdict '{"proof_anchors":["see the auth code","lib/template.sh:208"]}')"
assert_eq "prose + one substantive code quote -> solid" \
  "solid" \
  "$(verdict '{"proof_anchors":["check the handler","subprocess.run([cmd], shell=True)"]}')"

echo ""
echo "--- Group 7: verdict on STDOUT, rejection reasons on STDERR, rc mirrors house pattern ---"
# solid: verdict on stdout, rc 0, and the verdict token must NOT leak onto stderr.
run_va '{"proof_anchors":["lib/template.sh:208"]}'
assert_eq "solid verdict is printed on stdout" "solid" "$VA_OUT"
assert_eq "solid returns 0 (success, like validate_verification_manifest)" "0" "$VA_RC"
assert_not_contains "the verdict token is not emitted on stderr" "$VA_ERR" "solid"
# weak: verdict on stdout, rejection specifics on stderr, rc non-zero.
run_va '{"proof_anchors":["see the auth code"]}'
assert_eq "weak verdict is printed on stdout" "weak" "$VA_OUT"
assert_ne "weak returns non-zero (failure path)" "0" "$VA_RC"
assert_nonempty "weak emits rejection reason(s) on stderr" "$VA_ERR"
assert_contains "stderr names the rejected anchor" "$VA_ERR" "see the auth code"
# none: verdict on stdout, rc non-zero.
run_va '{"proof_anchors":[]}'
assert_eq "none verdict is printed on stdout" "none" "$VA_OUT"
assert_ne "none returns non-zero (failure path)" "0" "$VA_RC"

echo ""
echo "--- Group 8: verdict is ALWAYS exactly one legal token ---"
# Acceptance criterion: prints exactly one of solid/weak/none for every input.
while IFS= read -r j; do
  [[ -z "$j" ]] && continue
  assert_member "legal-verdict guard for: $j" "$(verdict "$j")"
done <<'EOF'
{"proof_anchors":["lib/template.sh:208"]}
{"proof_anchors":["see the auth code"]}
{"proof_anchors":[]}
{"proof_anchors":null}
{"proof_anchors":"app.py:1"}
{"proof_anchors":["a:1","prose only here"]}
{}
EOF

echo ""
echo "--- Group 9: purity (deterministic, no CWD side effects) + injection safety ---"
TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
PURE_DIR="$(mktemp -d "$TMPROOT/proofanchors-pure.XXXXXX")"
INJ_DIR="$(mktemp -d "$TMPROOT/proofanchors-inj.XXXXXX")"
trap 'rm -rf "$PURE_DIR" "$INJ_DIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

# Same input twice -> byte-identical verdict.
idem_json='{"proof_anchors":["lib/template.sh:208"]}'
assert_eq "validator is deterministic (same input -> same verdict)" \
  "$(verdict "$idem_json")" \
  "$(verdict "$idem_json")"

# The bare (1-arg) form must not write any file into the CWD.
( cd "$PURE_DIR" && validate_proof_anchors "$idem_json" >/dev/null 2>&1 )
TOTAL=$((TOTAL + 1))
created="$(find "$PURE_DIR" -mindepth 1 -print -quit 2>/dev/null)"
if [[ -z "$created" ]]; then
  pass_with "bare validator creates no files in CWD"
else
  fail_with "bare validator creates no files in CWD" "Unexpected file created: $created"
fi

# Injection: an anchor that WOULD run a command if the value were eval'd. The
# value must flow through jq as data — no file must be created, and the verdict
# must still be a legal token. Built via jq --arg so the literal reaches the
# function intact.
inj_json="$(jq -cn --arg a '$(touch INJECTED.txt)' '{proof_anchors:[$a]}')"
( cd "$INJ_DIR" && validate_proof_anchors "$inj_json" >/dev/null 2>&1 )
TOTAL=$((TOTAL + 1))
if [[ ! -e "$INJ_DIR/INJECTED.txt" ]]; then
  pass_with "command-substitution anchor is NOT evaluated (no file created)"
else
  fail_with "command-substitution anchor is NOT evaluated" "INJECTED.txt was created — the value was eval'd"
fi
assert_member "hostile anchor still yields a legal verdict (no crash, no eval)" \
  "$(verdict "$inj_json")"
# A thoroughly hostile value (quotes, semicolons, backticks, $(...), backslash)
# must not break classification or be interpreted — it just yields a legal token.
hostile_json="$(jq -cn --arg a '"; rm -rf x; echo solid `id` $(whoami) && \ end' \
  '{proof_anchors:[$a]}')"
assert_member "hostile anchor string yields a legal verdict" \
  "$(verdict "$hostile_json")"

echo ""
echo "--- Group 10: classifier (#334) consumes this verdict, not array length (AC 4) ---"
# After the refactor, classify_validation_status must derive anchor strength from
# validate_proof_anchors. Observable tightening: a prose-only anchor (weak, not
# solid) paired with a runnable LOCAL command must NOT classify `new` — it parks
# as needs-validation. Before the refactor (length >= 1 == solid) this returns
# `new`, so this assertion is RED until the classifier is rewired.
if declare -F classify_validation_status >/dev/null 2>&1; then
  assert_eq "prose-only anchor + local cmd -> needs-validation (weak anchors, not new)" \
    "needs-validation" \
    "$(classify_validation_status '{"proof_anchors":["see the auth code"],"suggested_validation":"grep -n x app.py"}' 2>/dev/null)"
  assert_ne "prose-only anchor + local cmd never classifies new" \
    "new" \
    "$(classify_validation_status '{"proof_anchors":["see the auth code"],"suggested_validation":"grep -n x app.py"}' 2>/dev/null)"
  # Regression guard: a genuine path:line anchor + local cmd still classifies new.
  assert_eq "path:line anchor + local cmd -> new (solid anchors, unchanged)" \
    "new" \
    "$(classify_validation_status '{"proof_anchors":["lib/template.sh:208"],"suggested_validation":"grep -n x app.py"}' 2>/dev/null)"
  # A substantive code quote now counts as solid evidence -> new with a local cmd.
  assert_eq "code-quote anchor + local cmd -> new (code quote is solid)" \
    "new" \
    "$(classify_validation_status '{"proof_anchors":["subprocess.run([cmd], shell=True)"],"suggested_validation":"grep -n x app.py"}' 2>/dev/null)"
else
  fail_with "classify_validation_status is defined (needed for the #334 refactor)" \
    "Missing classify_validation_status — cannot verify AC 4 wiring"
fi

echo ""
echo "--- Group 11: optional project-path containment check (best-effort, issue 'Optionally …') ---"
# The implemented 2-arg form validates that a `path:line` anchor's file actually
# exists under the given project. This whole branch is unexercised by the 1-arg
# groups above. SCRIPT_DIR is the repo root (a real project tree), so
# `lib/template.sh` exists under it and a `…_zzz.sh` path does not. These reads
# are read-only (`-e`/`-d`) — no files are created, so no cleanup is needed.
PROJ="$SCRIPT_DIR"

# A real, on-disk path:line under the project still reads as solid (the optional
# arg must not break a legitimate reference).
run_va '{"proof_anchors":["lib/template.sh:208"]}' "$PROJ"
assert_eq "path:line whose file EXISTS under project -> solid" "solid" "$VA_OUT"
assert_eq "existing-file path:line returns 0 (solid)" "0" "$VA_RC"
assert_eq "no rejection reason for a verifiable anchor" "" "$VA_ERR"

# A shaped path:line whose file is MISSING under the project is not counted as
# solid; with no other usable anchor the verdict downgrades to weak (NOT none —
# it is still a non-empty anchor) and the file is named on stderr.
run_va '{"proof_anchors":["lib/nope_does_not_exist_zzz.sh:99"]}' "$PROJ"
assert_eq "path:line to a MISSING project file -> downgraded to weak" "weak" "$VA_OUT"
assert_ne "missing-file path:line is never solid" "solid" "$VA_OUT"
assert_ne "missing-file path:line returns non-zero" "0" "$VA_RC"
assert_contains "stderr reports the file as not found under project" "$VA_ERR" "not found"
assert_contains "stderr names the unverifiable anchor" "$VA_ERR" "lib/nope_does_not_exist_zzz.sh:99"

# A substantive code quote is well-formed by shape, not by file existence, so the
# containment check leaves it alone.
run_va '{"proof_anchors":["subprocess.run([cmd], shell=True)"]}' "$PROJ"
assert_eq "code-quote anchor is unaffected by containment -> solid" "solid" "$VA_OUT"

# The guard is `-d <project_path>`: a non-existent / non-directory project path
# means "project unknown", so containment is SKIPPED and the same missing-file
# anchor that downgraded above now stays solid by shape. This keeps the function
# usable when the caller cannot supply a real project root.
run_va '{"proof_anchors":["lib/nope_does_not_exist_zzz.sh:99"]}' "$SCRIPT_DIR/.no-such-project-dir-zzz"
assert_eq "non-directory project path -> containment skipped, shaped anchor stays solid" \
  "solid" "$VA_OUT"

# >=1 well-formed wins even under containment: a missing-file path:line plus a
# valid code quote is still solid, while stderr still flags the unverifiable one.
run_va '{"proof_anchors":["lib/nope_does_not_exist_zzz.sh:1","subprocess.run([cmd], shell=True)"]}' "$PROJ"
assert_eq "missing-file path:line + valid code quote -> solid (>=1 well-formed wins)" \
  "solid" "$VA_OUT"
assert_contains "stderr still flags the unverifiable path:line in a mixed set" \
  "$VA_ERR" "not found"

echo ""
echo "--- Group 12: substantive-code-quote definition boundaries (length AND code-ish density) ---"
# A code quote qualifies only when it is BOTH long enough AND structurally
# code-ish. The wide-margin fixtures above never probe either floor; these lock
# both conjuncts and the deliberate exclusion of `.` `_` `-` from the code-ish
# set. Fixtures are chosen so the split holds for any sane tuning of the length
# threshold (the code-ish floor of >=2 is fixed, not tunable).

# Length is satisfied (>>12 chars) but there is only ONE code-ish char (`=`):
# fails the >=2 structural-character floor -> weak. (Independent of the length
# constant.)
assert_eq "long anchor with only one code-ish char -> weak (needs >=2 structural chars)" \
  "weak" \
  "$(verdict '{"proof_anchors":["set the flag value = true here"]}')"

# Structurally dense (`=` and `;`) but trivially short: fails the
# substantive-length floor -> weak. A 4-char fragment is below any plausible
# tuning of the threshold, so this guards against treating a tiny snippet as proof.
assert_eq "short code-dense fragment -> weak (below substantive-length floor)" \
  "weak" \
  "$(verdict '{"proof_anchors":["a=1;"]}')"

# A dotted identifier is long enough but `.` earns no code credit (deliberately
# excluded, with `_`/`-`, because dots are pervasive in prose and paths) -> weak.
assert_eq "dotted identifier 'app.config.get' -> weak (. _ - are not code-ish)" \
  "weak" \
  "$(verdict '{"proof_anchors":["app.config.get"]}')"

finish
