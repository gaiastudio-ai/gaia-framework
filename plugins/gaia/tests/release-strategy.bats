#!/usr/bin/env bats
# release-strategy.bats — acceptance tests for release.strategy config.
#
# Validates the three strategy modes (conventional-commits, manual, calendar)
# and the absent-defaults-to-manual invariant via the
# resolve-release-version.sh dispatch script.
#
# All tests use $TEST_TMP fixtures — never touches the working tree.

load 'test_helper.bash'

REPO_ROOT=""
RESOLVE_SCRIPT=""
CLASSIFY_JS=""

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RESOLVE_SCRIPT="$BATS_TEST_DIRNAME/../skills/gaia-release/scripts/resolve-release-version.sh"
  CLASSIFY_JS="$REPO_ROOT/scripts/classify-commits.js"
  export CLASSIFY_COMMITS_JS="$CLASSIFY_JS"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helper: scaffold a minimal project-config.yaml in $TEST_TMP
# ---------------------------------------------------------------------------
_scaffold_config() {
  local strategy="${1:-}"
  mkdir -p "$TEST_TMP/.gaia/config"
  {
    printf 'project_name: test-project\n'
    printf 'release:\n'
    printf '  version_files:\n'
    printf '    - VERSION\n'
    if [ -n "$strategy" ]; then
      printf '  strategy: %s\n' "$strategy"
    fi
  } > "$TEST_TMP/.gaia/config/project-config.yaml"

  # Plain-text version file for version-bump.js consumption.
  printf '1.2.3\n' > "$TEST_TMP/VERSION"
}

# Helper: scaffold a git repo with conventional commits.
_scaffold_git_repo() {
  cd "$TEST_TMP"
  git init -q
  git config user.email "test@gaia.local"
  git config user.name "Test User"
  git config commit.gpgsign false
  echo "init" > init.txt
  git add -A && git commit -q -m "chore: initial commit"
  git tag v1.2.3
}

# ---------------------------------------------------------------------------
# AC1: conventional-commits strategy — derive semver from commits
# ---------------------------------------------------------------------------

@test "conventional-commits strategy: feat commit derives minor bump" {
  _scaffold_config "conventional-commits"
  _scaffold_git_repo
  echo "feat" > feat.txt
  git add -A && git commit -q -m "feat: add new feature"

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump=minor"* ]]
}

@test "conventional-commits strategy: fix commit derives patch bump" {
  _scaffold_config "conventional-commits"
  _scaffold_git_repo
  echo "fix" > fix.txt
  git add -A && git commit -q -m "fix: resolve crash"

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump=patch"* ]]
}

@test "conventional-commits strategy: breaking change derives major bump" {
  _scaffold_config "conventional-commits"
  _scaffold_git_repo
  echo "breaking" > breaking.txt
  git add -A && git commit -q -m "feat!: redesign API"

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump=major"* ]]
}

@test "conventional-commits strategy: breaking change in body derives major bump" {
  _scaffold_config "conventional-commits"
  _scaffold_git_repo
  echo "break-body" > break-body.txt
  git add -A && git commit -q -m "feat: update API

BREAKING CHANGE: removed legacy endpoint"

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump=major"* ]]
}

@test "conventional-commits strategy: mixed commits take highest precedence" {
  _scaffold_config "conventional-commits"
  _scaffold_git_repo
  echo "a" > a.txt
  git add -A && git commit -q -m "fix: patch-level fix"
  echo "b" > b.txt
  git add -A && git commit -q -m "feat: new capability"

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump=minor"* ]]
}

# ---------------------------------------------------------------------------
# AC2: manual strategy — prompt passthrough, no commit-derivation
# ---------------------------------------------------------------------------

@test "manual strategy: emits strategy=manual for caller to handle" {
  _scaffold_config "manual"

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strategy=manual"* ]]
  # Must NOT contain a bump= line (caller prompts for the version).
  [[ "$output" != *"bump=patch"* ]]
  [[ "$output" != *"bump=minor"* ]]
  [[ "$output" != *"bump=major"* ]]
}

# ---------------------------------------------------------------------------
# AC3: calendar strategy — derive CalVer
# ---------------------------------------------------------------------------

@test "calendar strategy: derives CalVer version from current date" {
  _scaffold_config "calendar"

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strategy=calendar"* ]]
  # CalVer format: YYYY.MM.PATCH — extract and validate.
  local ver_line
  ver_line=$(echo "$output" | grep '^version=')
  [ -n "$ver_line" ]
  local ver="${ver_line#version=}"
  # Must start with a 4-digit year and a dot.
  [[ "$ver" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# AC4: absent strategy — defaults to manual
# ---------------------------------------------------------------------------

@test "absent strategy defaults to manual" {
  _scaffold_config ""  # no strategy key

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strategy=manual"* ]]
}

# ---------------------------------------------------------------------------
# AC5: conventional-commits with no releasable changes — clean exit
# ---------------------------------------------------------------------------

@test "conventional-commits with no releasable commits exits cleanly" {
  _scaffold_config "conventional-commits"
  _scaffold_git_repo
  # Only non-qualifying commits after the tag.
  echo "c" > c.txt
  git add -A && git commit -q -m "not a conventional commit at all"

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump=none"* ]]
  [[ "$output" == *"no releasable changes"* ]]
}

@test "conventional-commits with only skip-ci commits exits cleanly" {
  _scaffold_config "conventional-commits"
  _scaffold_git_repo
  echo "d" > d.txt
  git add -A && git commit -q -m "chore(release): bump version [skip ci]"

  run bash "$RESOLVE_SCRIPT" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump=none"* ]]
  [[ "$output" == *"no releasable changes"* ]]
}

# ---------------------------------------------------------------------------
# Schema: SKILL.md documents the strategy config
# ---------------------------------------------------------------------------

@test "SKILL.md documents the three release strategy modes" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-release/SKILL.md"
  [ -f "$skill_md" ]
  run cat "$skill_md"
  [[ "$output" == *"conventional-commits"* ]]
  [[ "$output" == *"manual"* ]]
  [[ "$output" == *"calendar"* ]]
}

@test "SKILL.md documents the no-releasable-changes clean exit" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-release/SKILL.md"
  run cat "$skill_md"
  [[ "$output" == *"no releasable changes"* ]] || [[ "$output" == *"exit 0"* ]] || [[ "$output" == *"clean exit"* ]]
}

@test "SKILL.md documents release.strategy config key" {
  local skill_md="$BATS_TEST_DIRNAME/../skills/gaia-release/SKILL.md"
  run cat "$skill_md"
  [[ "$output" == *"release.strategy"* ]] || [[ "$output" == *"strategy:"* ]]
}

# ---------------------------------------------------------------------------
# Schema: JSON schema includes the strategy enum
# ---------------------------------------------------------------------------

@test "project-config.schema.json release object includes strategy enum" {
  local schema="$BATS_TEST_DIRNAME/../schemas/project-config.schema.json"
  [ -f "$schema" ]
  # Extract strategy enum values from JSON schema.
  run jq -r '.properties.release.properties.strategy.enum[]' "$schema"
  [ "$status" -eq 0 ]
  [[ "$output" == *"conventional-commits"* ]]
  [[ "$output" == *"manual"* ]]
  [[ "$output" == *"calendar"* ]]
}

# ---------------------------------------------------------------------------
# Script: resolve-release-version.sh exists and is executable
# ---------------------------------------------------------------------------

@test "resolve-release-version.sh exists under the release skill scripts dir" {
  [ -f "$RESOLVE_SCRIPT" ]
  [ -x "$RESOLVE_SCRIPT" ]
}
