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

# Tests for issue #63 — base prompt forge command rendering.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/forge.sh"
source "$SCRIPT_DIR/lib/template.sh"

PASS=0
FAIL=0
TOTAL=0
TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/forge-prompt-rendering.XXXXXX")"
trap 'rm -rf "$TMPDIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected to contain: '$needle')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (did not expect: '$needle')"
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

cat > "$TMPDIR/lens.md" <<'EOF'
---
id: naming
domain: code-quality
name: Naming Lens
role: Test Role
---

## Your Expert Focus

Check naming problems.
EOF

render_prompt() {
  local provider="$1" base_name="${2:-audit}" repo_slug="${3:-owner/repo}" project_path="${4:-$TMPDIR/local checkout}"
  local label="audit:code-quality/naming"
  local color="ededed"
  local base_file="$SCRIPT_DIR/prompts/_base/${base_name}.md"

  FORGE_PROVIDER="$provider"
  FORGE_HOST="codeberg.org"
  FORGE_REMOTE_NAME="origin"
  FORGE_PROJECT_PATH="$project_path"

  local vars=""
  vars="PROJECT_PATH=${project_path}"
  vars+="|DOMAIN=code-quality"
  vars+="|DOMAIN_NAME=Code Quality"
  vars+="|DOMAIN_COLOR=${color}"
  vars+="|LENS_ID=naming"
  vars+="|LENS_NAME=Naming Lens"
  vars+="|LENS_LABEL=${label}"
  vars+="|MODE=${base_name}"
  vars+="|RUN_ID=test-run"
  vars+="|REPO_NAME=local checkout"
  vars+="|REPO_OWNER=owner"
  vars+="|FORGE_REPO_SLUG=${repo_slug}"
  vars+="|FORGE_ISSUE_CREATE=$(forge_prompt_issue_create "$label" "$repo_slug" "$project_path")"
  vars+="|FORGE_LABEL_CREATE=$(forge_prompt_label_create "$label" "$color" "$repo_slug" "$project_path")"
  vars+="|FORGE_ENHANCEMENT_LABEL_CREATE=$(forge_prompt_label_create "enhancement" "a2eeef" "$repo_slug" "$project_path")"
  vars+="|FORGE_ISSUE_LIST_OPEN=$(forge_prompt_issue_list "open" "$repo_slug" "$project_path")"
  vars+="|FORGE_ISSUE_LIST_CLOSED=$(forge_prompt_issue_list "closed" "$repo_slug" "$project_path")"

  compose_prompt "$base_file" "$TMPDIR/lens.md" "$vars" "" "$base_name" ""
}

echo ""
echo "=== Test Suite: forge prompt rendering (issue #63) ==="
echo ""

echo "--- Group 1: remote repo slug parsing ---"
assert_eq "HTTPS remote parses owner/repo" \
  "origin-owner/origin-repo" \
  "$(forge_remote_repo_slug "https://github.com/origin-owner/origin-repo.git")"
assert_eq "HTTPS remote without .git parses owner/repo" \
  "origin-owner/origin-repo" \
  "$(forge_remote_repo_slug "https://github.com/origin-owner/origin-repo")"
assert_eq "SSH scp-like remote parses owner/repo" \
  "origin-owner/origin-repo" \
  "$(forge_remote_repo_slug "git@github.com:origin-owner/origin-repo.git")"
assert_eq "SSH URL remote parses owner/repo" \
  "origin-owner/origin-repo" \
  "$(forge_remote_repo_slug "ssh://git@github.com/origin-owner/origin-repo.git")"
assert_eq "HTTPS base-path remote uses the final owner/repo pair" \
  "origin-owner/origin-repo" \
  "$(forge_remote_repo_slug "https://forge.example.com/git/origin-owner/origin-repo.git")"

echo ""
echo "--- Group 2: provider-specific rendered audit prompt commands ---"
gh_prompt="$(render_prompt gh audit owner/repo "$TMPDIR/local checkout")"
assert_contains "gh issue create rendered" "gh issue create" "$gh_prompt"
assert_contains "gh issue create targets repo slug" "-R owner/repo" "$gh_prompt"
assert_contains "gh label create rendered" "gh label create audit:code-quality/naming --color ededed --force -R owner/repo" "$gh_prompt"
assert_contains "gh issue list rendered" "gh issue list -R owner/repo --state open --limit 100" "$gh_prompt"
assert_not_contains "gh prompt has no raw forge placeholders" "{{FORGE_" "$gh_prompt"

tea_prompt="$(render_prompt tea audit owner/repo "$TMPDIR/local checkout")"
assert_contains "tea issue create rendered" "tea issues create" "$tea_prompt"
assert_contains "tea issue create uses description flag" "--description" "$tea_prompt"
assert_contains "tea issue create uses label flag" "--labels audit:code-quality/naming" "$tea_prompt"
assert_contains "tea target stays bound to project path and remote" "--repo '$TMPDIR/local checkout' --remote origin" "$tea_prompt"
assert_contains "tea label create rendered" "tea labels create --name audit:code-quality/naming --color ededed" "$tea_prompt"
assert_contains "tea issue list rendered" "tea issues list --repo '$TMPDIR/local checkout' --remote origin --state open --limit 100" "$tea_prompt"
assert_not_contains "tea prompt has no gh issue command" "gh issue" "$tea_prompt"
assert_not_contains "tea prompt has no gh label command" "gh label" "$tea_prompt"
assert_not_contains "tea prompt has no raw forge placeholders" "{{FORGE_" "$tea_prompt"

fj_prompt="$(render_prompt fj audit owner/repo "$TMPDIR/local checkout")"
assert_contains "fj issue create rendered" "fj -H codeberg.org issue create --repo owner/repo" "$fj_prompt"
assert_contains "fj label application rendered" 'fj -H codeberg.org issue edit "owner/repo#$issue_number" labels --add audit:code-quality/naming' "$fj_prompt"
assert_contains "fj URL issue number extraction rendered" 'issue_number="${issue_output##*issues/}"' "$fj_prompt"
assert_contains "fj hash issue number extraction rendered" 'issue_number="${issue_number:-${issue_output##*#}}"' "$fj_prompt"
assert_contains "fj label create rendered" "fj -H codeberg.org repo labels owner/repo create audit:code-quality/naming ededed" "$fj_prompt"
assert_contains "fj issue list rendered" "fj -H codeberg.org --style minimal issue search --repo owner/repo --state open" "$fj_prompt"
assert_not_contains "fj prompt has no gh issue command" "gh issue" "$fj_prompt"
assert_not_contains "fj prompt has no gh label command" "gh label" "$fj_prompt"
assert_not_contains "fj prompt has no non-executable prose" "then identify" "$fj_prompt"
assert_not_contains "fj prompt has no raw forge placeholders" "{{FORGE_" "$fj_prompt"

fj_create="$(FORGE_PROVIDER=fj FORGE_HOST=codeberg.org forge_prompt_issue_create "audit:code-quality/naming" "owner/repo" "$TMPDIR/local checkout")"
bash -n -c "$fj_create"
assert_rc_zero "fj issue-create prompt command parses as Bash" "$?"

echo ""
echo "--- Group 3: discover enhancement label rendering ---"
for provider in gh tea fj; do
  prompt="$(render_prompt "$provider" discover owner/repo "$TMPDIR/local checkout")"
  case "$provider" in
    gh)
      assert_contains "discover gh enhancement label command" "gh label create enhancement --color a2eeef --force -R owner/repo" "$prompt"
      ;;
    tea)
      assert_contains "discover tea enhancement label command" "tea labels create --name enhancement --color a2eeef --repo '$TMPDIR/local checkout' --remote origin" "$prompt"
      assert_not_contains "discover tea contains no gh commands" "gh label" "$prompt"
      ;;
    fj)
      assert_contains "discover fj enhancement label command" "fj -H codeberg.org repo labels owner/repo create enhancement a2eeef" "$prompt"
      assert_not_contains "discover fj contains no gh commands" "gh label" "$prompt"
      ;;
  esac
  assert_not_contains "discover $provider has no raw forge placeholders" "{{FORGE_" "$prompt"
done

echo ""
echo "--- Group 4: renamed checkout regression ---"
renamed_project="$TMPDIR/local-dir"
mkdir -p "$renamed_project"
remote_slug="$(forge_remote_repo_slug "https://github.com/acme/origin-repo.git")"

gh_renamed_prompt="$(render_prompt gh audit "$remote_slug" "$renamed_project")"
assert_contains "gh prompt uses origin repo slug when checkout name differs" "-R acme/origin-repo" "$gh_renamed_prompt"
assert_not_contains "gh prompt does not target checkout basename" "-R acme/local-dir" "$gh_renamed_prompt"

fj_renamed_prompt="$(render_prompt fj audit "$remote_slug" "$renamed_project")"
assert_contains "fj prompt uses origin repo slug when checkout name differs" "--repo acme/origin-repo" "$fj_renamed_prompt"
assert_not_contains "fj prompt does not target checkout basename" "--repo acme/local-dir" "$fj_renamed_prompt"

tea_renamed_prompt="$(render_prompt tea audit "$remote_slug" "$renamed_project")"
assert_contains "tea prompt remains project-path bound" "--repo '$renamed_project' --remote origin" "$tea_renamed_prompt"
assert_not_contains "tea prompt does not switch to slug target" "--repo acme/origin-repo" "$tea_renamed_prompt"

echo ""
echo "--- Group 5: every base prompt resolves forge placeholders ---"
for base_file in "$SCRIPT_DIR"/prompts/_base/*.md; do
  base_name="$(basename "$base_file" .md)"
  for provider in gh tea fj; do
    prompt="$(render_prompt "$provider" "$base_name" owner/repo "$TMPDIR/local checkout")"
    assert_not_contains "$base_name $provider has no raw forge placeholders" "{{FORGE_" "$prompt"
  done
done

echo ""
echo "--- Group 6: base templates contain no literal gh issue/label commands ---"
if grep_out="$(grep -rnE '\bgh (issue|label) ' "$SCRIPT_DIR/prompts/_base" 2>/dev/null)"; then
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: base prompt grep found literal gh issue/label commands"
  printf '%s\n' "$grep_out" | sed 's/^/    /'
else
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: base prompt grep found no literal gh issue/label commands"
fi

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
