#!/usr/bin/env bats
# dev-story-promotion-chain-detect.bats — coverage for the upward-walk
# config-discovery ladder added to promotion-chain-guard.sh by E55-S9.
#
# Story: E55-S9 — Fix dev-story skill promotion-chain ABSENT false-flag
# Refs:  AC1, AC3, AC4 (regression for sprint-37 / E53-S244 / E69-S4)
#
# These tests exercise the case the original promotion-chain-guard.bats did
# not cover: the script being invoked from a CWD that does NOT contain a
# config/ directory directly, but whose ancestor does. Before the E55-S9
# fix, the guard returned ABSENT in that scenario (false-flag) and Steps
# 13-16 of /gaia-dev-story were silently skipped.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  GUARD="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/promotion-chain-guard.sh"
  # The guard now skip-with-warns on non-git CWD; init a git work tree so we
  # exercise the real PRESENT/ABSENT contract.
  git init -q "$TEST_TMP" 2>/dev/null || true
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — promotion chain configured at an ancestor: PRESENT, exit 0
# Reproduces the sprint-37 layout: project-root/config/project-config.yaml
# with a sub-tree (gaia-framework/) that has no config/ of its own. The guard
# MUST walk upward from $PWD to find the team-shared config.
# ---------------------------------------------------------------------------

@test "promotion-chain-detect: PRESENT detected via upward walk from sub-tree" {
  mkdir -p "$TEST_TMP/config" "$TEST_TMP/sub/gaia-framework"
  cat > "$TEST_TMP/config/project-config.yaml" <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      name: Staging
      branch: staging
      ci_provider: github_actions
EOF
  # A sub-tree with no config/ of its own — this is the gaia-framework/ shape.
  ( cd "$TEST_TMP/sub/gaia-framework" && git init -q . 2>/dev/null || true )
  # Invoke from the sub-tree; PROJECT_CONFIG is intentionally unset so the
  # discovery ladder fires.
  cd "$TEST_TMP/sub/gaia-framework"
  unset PROJECT_CONFIG
  run "$GUARD"
  [ "$status" -eq 0 ]
  [ "$output" = "PRESENT:staging" ]
}

# ---------------------------------------------------------------------------
# AC3 — genuinely absent: no config/ anywhere in the ancestry → ABSENT, exit 1
# The existing AC3 behavior MUST be preserved.
# ---------------------------------------------------------------------------

@test "promotion-chain-detect: ABSENT detected when no config in ancestry" {
  mkdir -p "$TEST_TMP/standalone"
  ( cd "$TEST_TMP/standalone" && git init -q . 2>/dev/null || true )
  cd "$TEST_TMP/standalone"
  unset PROJECT_CONFIG
  run --separate-stderr "$GUARD"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ABSENT"* ]]
  [[ "$stderr" == *"/gaia-ci-edit"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — sprint-37 regression case: layout mirrors GAIA-Framework/gaia-framework/
# ---------------------------------------------------------------------------

@test "promotion-chain-detect: sprint-37 regression — gaia-framework CWD with parent config" {
  # Mirror the real GAIA-Framework layout:
  #   $TEST_TMP/                       <- "GAIA-Framework"
  #     config/project-config.yaml     <- team-shared with promotion_chain
  #     gaia-framework/                   <- where /gaia-dev-story runs from
  #       plugins/gaia/...
  mkdir -p "$TEST_TMP/config" "$TEST_TMP/gaia-framework/plugins/gaia"
  cat > "$TEST_TMP/config/project-config.yaml" <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      branch: staging
    - id: main
      branch: main
EOF
  ( cd "$TEST_TMP/gaia-framework" && git init -q . 2>/dev/null || true )
  cd "$TEST_TMP/gaia-framework"
  unset PROJECT_CONFIG
  run --separate-stderr "$GUARD"
  [ "$status" -eq 0 ]
  [ "$output" = "PRESENT:staging" ]
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------------------
# CLAUDE_PROJECT_ROOT env override is honored above the upward walk
# ---------------------------------------------------------------------------

@test "promotion-chain-detect: CLAUDE_PROJECT_ROOT override wins over walk" {
  mkdir -p "$TEST_TMP/proj/config" "$TEST_TMP/elsewhere"
  cat > "$TEST_TMP/proj/config/project-config.yaml" <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      branch: my-staging
EOF
  ( cd "$TEST_TMP/elsewhere" && git init -q . 2>/dev/null || true )
  cd "$TEST_TMP/elsewhere"
  unset PROJECT_CONFIG
  CLAUDE_PROJECT_ROOT="$TEST_TMP/proj" run "$GUARD"
  [ "$status" -eq 0 ]
  [ "$output" = "PRESENT:my-staging" ]
}

# ---------------------------------------------------------------------------
# Explicit PROJECT_CONFIG env still wins (backward-compat with existing bats)
# ---------------------------------------------------------------------------

@test "promotion-chain-detect: explicit PROJECT_CONFIG wins over discovery" {
  mkdir -p "$TEST_TMP/config" "$TEST_TMP/sub"
  cat > "$TEST_TMP/config/project-config.yaml" <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      branch: walk-branch
EOF
  mkdir -p "$TEST_TMP/explicit"
  cat > "$TEST_TMP/explicit/explicit-config.yaml" <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      branch: explicit-branch
EOF
  ( cd "$TEST_TMP/sub" && git init -q . 2>/dev/null || true )
  cd "$TEST_TMP/sub"
  PROJECT_CONFIG="$TEST_TMP/explicit/explicit-config.yaml" run "$GUARD"
  [ "$status" -eq 0 ]
  [ "$output" = "PRESENT:explicit-branch" ]
}
