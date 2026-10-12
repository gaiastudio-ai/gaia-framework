#!/usr/bin/env bats
# classify-commits-shipped.bats — verify that the commit classifier is shipped
# inside the plugin and that the conventional-commits release strategy resolves
# it from an external project directory (not inside the framework repo).

load 'test_helper.bash'

PLUGIN_ROOT=""
RESOLVE_SCRIPT=""

setup() {
  common_setup
  # PLUGIN_ROOT points at the plugin dir (plugins/gaia/) within the repo.
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVE_SCRIPT="$PLUGIN_ROOT/skills/gaia-release/scripts/resolve-release-version.sh"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# The classifier file exists inside the plugin
# ---------------------------------------------------------------------------

@test "classify-commits.js is shipped inside the plugin scripts dir" {
  [ -f "$PLUGIN_ROOT/scripts/classify-commits.js" ]
}

@test "classify-commits.js is executable or node-runnable" {
  # It must be readable and invokable by node.
  [ -r "$PLUGIN_ROOT/scripts/classify-commits.js" ]
  run node "$PLUGIN_ROOT/scripts/classify-commits.js" "feat(x): hello\n"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump_size=minor"* ]]
}

# ---------------------------------------------------------------------------
# Resolver finds the classifier via CLAUDE_PLUGIN_ROOT from an external dir
# ---------------------------------------------------------------------------

@test "conventional-commits strategy resolves from external project via CLAUDE_PLUGIN_ROOT" {
  # Scaffold a project directory OUTSIDE the framework repo.
  local ext_project="$TEST_TMP/user-project"
  mkdir -p "$ext_project/.gaia/config"

  cat > "$ext_project/.gaia/config/project-config.yaml" <<'YAML'
project_name: external-test
release:
  strategy: conventional-commits
  version_files:
    - VERSION
YAML

  printf '0.1.0\n' > "$ext_project/VERSION"

  # Create a git repo with a conventional commit.
  cd "$ext_project"
  git init -q
  git config user.email "test@gaia.local"
  git config user.name "Test User"
  git config commit.gpgsign false
  echo "init" > init.txt
  git add -A && git commit -q -m "chore: initial commit"
  git tag v0.1.0
  echo "feature" > feature.txt
  git add -A && git commit -q -m "feat: add a feature"

  # Run the resolver with CLAUDE_PLUGIN_ROOT set to the plugin dir.
  # CWD is the external project (not the framework repo).
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  run bash "$RESOLVE_SCRIPT" \
    --config "$ext_project/.gaia/config/project-config.yaml" \
    --project-root "$ext_project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strategy=conventional-commits"* ]]
  [[ "$output" == *"bump=minor"* ]]
}

@test "conventional-commits strategy fails with clear error when classifier path is invalid" {
  # Scaffold a project directory OUTSIDE the framework repo.
  local ext_project="$TEST_TMP/bare-project"
  mkdir -p "$ext_project/.gaia/config"

  cat > "$ext_project/.gaia/config/project-config.yaml" <<'YAML'
project_name: bare-test
release:
  strategy: conventional-commits
  version_files:
    - VERSION
YAML

  printf '0.1.0\n' > "$ext_project/VERSION"

  cd "$ext_project"
  git init -q
  git config user.email "test@gaia.local"
  git config user.name "Test User"
  git config commit.gpgsign false
  echo "init" > init.txt
  git add -A && git commit -q -m "chore: initial commit"
  git tag v0.1.0
  echo "feature" > feature.txt
  git add -A && git commit -q -m "feat: add a feature"

  # When CLASSIFY_COMMITS_JS points to a non-existent file, the resolver
  # should fail with exit 2 and a clear error message.
  export CLASSIFY_COMMITS_JS="$TEST_TMP/does-not-exist.js"
  unset CLAUDE_PLUGIN_ROOT
  run bash "$RESOLVE_SCRIPT" \
    --config "$ext_project/.gaia/config/project-config.yaml" \
    --project-root "$ext_project"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found"* ]]
}

@test "CLASSIFY_COMMITS_JS env override takes precedence over plugin root" {
  local ext_project="$TEST_TMP/override-project"
  mkdir -p "$ext_project/.gaia/config"

  cat > "$ext_project/.gaia/config/project-config.yaml" <<'YAML'
project_name: override-test
release:
  strategy: conventional-commits
  version_files:
    - VERSION
YAML

  printf '0.1.0\n' > "$ext_project/VERSION"

  cd "$ext_project"
  git init -q
  git config user.email "test@gaia.local"
  git config user.name "Test User"
  git config commit.gpgsign false
  echo "init" > init.txt
  git add -A && git commit -q -m "chore: initial commit"
  git tag v0.1.0
  echo "fix" > fix.txt
  git add -A && git commit -q -m "fix: patch a bug"

  # Point the override at the shipped copy.
  export CLASSIFY_COMMITS_JS="$PLUGIN_ROOT/scripts/classify-commits.js"
  unset CLAUDE_PLUGIN_ROOT
  run bash "$RESOLVE_SCRIPT" \
    --config "$ext_project/.gaia/config/project-config.yaml" \
    --project-root "$ext_project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump=patch"* ]]
}
