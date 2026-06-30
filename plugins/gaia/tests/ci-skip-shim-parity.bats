#!/usr/bin/env bats
# ci-skip-shim-parity.bats — the plugin-ci skip-shim must stay in lockstep with
# plugin-ci.yml.
#
# plugin-ci.yml emits the branch-protection-required contexts
# (frontmatter-lint, bats-tests, structure-validate) but is path-filtered to
# the product-source surface. plugin-ci-skip-shim.yml reports those same three
# contexts as no-ops on the INVERSE path set so a non-product PR (e.g.
# documentation-only) is mergeable without an admin override. If the shim's
# job names or its paths-ignore list drift from plugin-ci.yml, a docs-only PR
# silently blocks again. These tests pin the invariant.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../../.." && pwd )"
  CI="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  SHIM="$REPO_ROOT/.github/workflows/plugin-ci-skip-shim.yml"
}

teardown() { common_teardown; }

# Required (or intended-required) context names, sorted, extracted from a
# workflow's top-level jobs' `name:` fields restricted to the protected
# contexts. audit-v2-migration is included because plugin-ci.yml's own header
# instructs admins to mark it required and the shim covers it pre-emptively.
_required_names() {
  local file="$1"
  grep -E '^    name: (frontmatter-lint|bats-tests|structure-validate|audit-v2-migration)$' "$file" \
    | sed -E 's/^    name: //' | sort -u
}

# The path list under the workflow's pull_request `paths:` / `paths-ignore:`
# key, normalized (leading "- " stripped, sorted).
_path_list() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^    " key ":" { inblock=1; next }
    inblock && /^      - / { gsub(/^      - /,""); gsub(/[[:space:]'\''"]/,""); print; next }
    inblock && /^    [a-z]/ { inblock=0 }
    inblock && /^  [a-z]/ { inblock=0 }
  ' "$file" | sort -u
}

@test "the skip-shim workflow exists" {
  [ -f "$SHIM" ]
}

@test "shim job names exactly match plugin-ci's required contexts" {
  local ci_names shim_names
  ci_names="$(_required_names "$CI")"
  shim_names="$(_required_names "$SHIM")"
  echo "plugin-ci required: [$ci_names]"
  echo "shim emits:         [$shim_names]"
  # plugin-ci must declare all four protected jobs (guards the source too).
  [ "$(printf '%s\n' "$ci_names" | grep -c .)" -eq 4 ]
  [ "$ci_names" = "$shim_names" ]
}

@test "shim paths-ignore mirrors plugin-ci paths (inverse-trigger invariant)" {
  local ci_paths shim_ignore
  ci_paths="$(_path_list "$CI" paths)"
  shim_ignore="$(_path_list "$SHIM" paths-ignore)"
  echo "plugin-ci paths:    [$ci_paths]"
  echo "shim paths-ignore:  [$shim_ignore]"
  # Both sides must be non-empty AND identical — a simultaneously-empty
  # malformed pair must not slip through as "equal".
  [ -n "$ci_paths" ]
  [ -n "$shim_ignore" ]
  [ "$ci_paths" = "$shim_ignore" ]
}

@test "the inversion itself holds — plugin-ci uses paths:, shim uses paths-ignore:" {
  grep -qE '^    paths:' "$CI"
  ! grep -qE '^    paths-ignore:' "$CI"
  grep -qE '^    paths-ignore:' "$SHIM"
  ! grep -qE '^    paths:' "$SHIM"
}

@test "shim triggers on the same branches as plugin-ci (main + staging)" {
  for f in "$CI" "$SHIM"; do
    grep -qE '^    branches: \[main, staging\]' "$f"
  done
}

@test "shim jobs are no-ops — they must not run the real lint/test/validate scripts" {
  # A shim job that accidentally invoked the real script would defeat the
  # purpose (and fail on a tree with no product source). Inspect only the
  # executable `run:` step lines (not comments/prose), and assert none of the
  # real entrypoints appear.
  run_lines="$(grep -E '^\s+run:' "$SHIM" || true)"
  echo "run lines: $run_lines"
  ! printf '%s' "$run_lines" | grep -qE 'lint-skill-frontmatter|structure-validate\.sh|run-with-coverage|setup-bats'
}
