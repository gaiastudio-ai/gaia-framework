#!/usr/bin/env bats
# promotion-chain-guard.bats — coverage for skills/gaia-dev-story/scripts/promotion-chain-guard.sh
#
# Story: E57-S6 — promotion-chain-guard.sh (P0-3) + check-deps.sh (P1-1)
# Refs:  TC-DSS-04, FR-DSS-3, AC1, AC2

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  GUARD="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/promotion-chain-guard.sh"
  cd "$TEST_TMP"
  mkdir -p config
  # E53-S234: the guard now skip-with-warnings on non-git CWD. To exercise the
  # PRESENT/ABSENT contract, the test fixture must be inside a git work tree.
  git init -q "$TEST_TMP" 2>/dev/null || true
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — promotion chain configured -> PRESENT:<branch>, exit 0
# ---------------------------------------------------------------------------

@test "promotion-chain-guard: PRESENT path emits 'PRESENT:<branch>' on stdout, exit 0" {
  cat > config/project-config.yaml <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      name: Staging
      branch: staging
      ci_provider: github_actions
EOF
  PROJECT_CONFIG="$TEST_TMP/config/project-config.yaml" run "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^PRESENT:[a-z0-9-]+$ ]]
  [ "$output" = "PRESENT:staging" ]
}

@test "promotion-chain-guard: PRESENT path stderr is empty" {
  cat > config/project-config.yaml <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      branch: my-branch-1
EOF
  PROJECT_CONFIG="$TEST_TMP/config/project-config.yaml" run --separate-stderr "$GUARD"
  [ "$status" -eq 0 ]
  [ "$output" = "PRESENT:my-branch-1" ]
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------------------
# AC2 — promotion chain absent -> exit 1, stderr 'ABSENT' + remediation hint, stdout empty
# ---------------------------------------------------------------------------

@test "promotion-chain-guard: ABSENT path exits 1 when ci_cd block missing" {
  cat > config/project-config.yaml <<'EOF'
project_root: "/tmp"
framework_version: "1.0.0"
EOF
  PROJECT_CONFIG="$TEST_TMP/config/project-config.yaml" run --separate-stderr "$GUARD"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ABSENT"* ]]
  [[ "$stderr" == *"/gaia-ci-edit"* ]]
}

@test "promotion-chain-guard: ABSENT path exits 1 when promotion_chain key absent" {
  cat > config/project-config.yaml <<'EOF'
ci_cd:
  some_other_key: foo
EOF
  PROJECT_CONFIG="$TEST_TMP/config/project-config.yaml" run --separate-stderr "$GUARD"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ABSENT"* ]]
  [[ "$stderr" == *"/gaia-ci-edit"* ]]
}

@test "promotion-chain-guard: ABSENT path when config file does not exist" {
  PROJECT_CONFIG="$TEST_TMP/config/missing.yaml" run --separate-stderr "$GUARD"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ABSENT"* ]]
}

# ---------------------------------------------------------------------------
# Integration: cluster-7-chain shared fixture (Story Task 3 — fixture reuse)
# The fixture's project-config.yaml has no ci_cd block, so it exercises the
# ABSENT path against the canonical chain test data.
# ---------------------------------------------------------------------------

@test "promotion-chain-guard: cluster-7-chain fixture exercises ABSENT path" {
  local fixture_cfg
  fixture_cfg="$(cd "$BATS_TEST_DIRNAME/../../../tests/fixtures/cluster-7-chain/config" && pwd)/project-config.yaml"
  [ -f "$fixture_cfg" ]
  PROJECT_CONFIG="$fixture_cfg" run --separate-stderr "$GUARD"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ABSENT"* ]]
  [[ "$stderr" == *"/gaia-ci-edit"* ]]
}
