#!/usr/bin/env bats
# run-tests-contract.bats — E67-S6 coverage for the reference run-tests.sh
# (Test Execution Bridge contract per E17 / ADR-044 / FR-RSV2-11 / FR-RSV2-19).
#
# Refs: AC1, AC2, AC3, AC4, AC5.

bats_require_minimum_version 1.5.0

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  PLUGIN_SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
  RUN_TESTS_SH="$PLUGIN_SCRIPTS_DIR/run-tests.sh"

  local slug
  slug="$(printf '%s' "${BATS_TEST_NAME:-unknown}" | tr -c '[:alnum:]' '_')"
  TEST_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/run-tests-contract-${slug}-$$"
  mkdir -p "$TEST_TMP"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Helper: write a project-config.yaml with the given tier_1 placement and command.
write_config() {
  local cfg="$1" placement="$2" cmd="${3:-}"
  cat > "$cfg" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
framework_version: "1.134.1"
test_execution:
  tier_1:
    placement: ${placement}
    command: "${cmd}"
    timeout_seconds: 30
EOF
}

# --- AC5: header-comment block / --help ---------------------------------

@test "AC5: --help emits adapter-contract documentation" {
  [ -x "$RUN_TESTS_SH" ]
  run "$RUN_TESTS_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--story-key"* ]] || [[ "$output" == *"--story"* ]]
  [[ "$output" == *"--context"* ]] || [[ "$output" == *"--tier"* ]]
  # FR-RSV2-19 adapter-contract style header — the help block names the
  # public API.
  [[ "$output" == *"run-tests.sh"* ]]
}

@test "AC5: header-comment documents the public-API contract block" {
  run head -50 "$RUN_TESTS_SH"
  [ "$status" -eq 0 ]
  # Assert the contract the header carries, not an internal traceability ID
  # (those were scrubbed from published source). The header is the
  # adapter-contract-style Public API block naming the reference bridge entry.
  [[ "$output" == *"Reference Test Execution Bridge"* ]]
  [[ "$output" == *"Public API"* ]]
  [[ "$output" == *"--detect-runner"* ]]
}

# --- AC1 / AC2: tier discovery + placement enforcement ------------------

@test "AC1: --story-key + --context invokes tier_1 command when placement matches" {
  cfg="$TEST_TMP/project-config.yaml"
  write_config "$cfg" "local" "echo TIER1_RAN > $TEST_TMP/sentinel"
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story-key "E67-S6" --context "local"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/sentinel" ]
  grep -q "TIER1_RAN" "$TEST_TMP/sentinel"
}

@test "AC1: --story + --tier alias maps tier=unit -> tier_1" {
  cfg="$TEST_TMP/project-config.yaml"
  write_config "$cfg" "local" "echo UNIT_RAN > $TEST_TMP/sentinel"
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story "E67-S6" --tier "unit"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/sentinel" ]
  grep -q "UNIT_RAN" "$TEST_TMP/sentinel"
}

@test "AC2: ci-pre-merge placement refuses to run locally with clear error" {
  cfg="$TEST_TMP/project-config.yaml"
  write_config "$cfg" "ci-pre-merge" "echo SHOULD_NOT_RUN > $TEST_TMP/sentinel"
  run env GAIA_TESTS_CONFIG="$cfg" GAIA_EXECUTION_CONTEXT="local" "$RUN_TESTS_SH" --story-key "E67-S6" --context "local"
  [ "$status" -ne 0 ]
  [ ! -f "$TEST_TMP/sentinel" ]
  [[ "$output" == *"ci-pre-merge"* ]] || [[ "$output" == *"placement"* ]]
}

@test "AC2: emits suites JSON on stdout when running locally" {
  cfg="$TEST_TMP/project-config.yaml"
  write_config "$cfg" "local" "true"
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story-key "E67-S6" --context "local"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"suites"'* ]]
}

# --- Story-key shape validation (T-37 mitigation) -----------------------

@test "story-key shape validation: rejects path-traversal-style keys" {
  cfg="$TEST_TMP/project-config.yaml"
  write_config "$cfg" "local" "true"
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story-key "../etc/passwd" --context "local"
  [ "$status" -ne 0 ]
  [[ "$output" == *"story"* ]] || [[ "$output" == *"key"* ]]
}

# --- AC3: per-stack runner detection (Vitest, JUnit, pytest, Go, Maestro) ---

@test "AC3: detect_runner — Vitest via package.json" {
  proj="$TEST_TMP/proj-vitest"
  mkdir -p "$proj"
  cat > "$proj/package.json" <<'EOF'
{"name":"x","devDependencies":{"vitest":"^1.0.0"}}
EOF
  run "$RUN_TESTS_SH" --detect-runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "vitest" ]
}

@test "AC3: detect_runner — Vitest via vitest.config.ts" {
  proj="$TEST_TMP/proj-vitest-config"
  mkdir -p "$proj"
  : > "$proj/vitest.config.ts"
  run "$RUN_TESTS_SH" --detect-runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "vitest" ]
}

@test "AC3: detect_runner — JUnit via pom.xml" {
  proj="$TEST_TMP/proj-junit"
  mkdir -p "$proj"
  : > "$proj/pom.xml"
  run "$RUN_TESTS_SH" --detect-runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "junit" ]
}

@test "AC3: detect_runner — JUnit via build.gradle" {
  proj="$TEST_TMP/proj-junit-gradle"
  mkdir -p "$proj"
  : > "$proj/build.gradle"
  run "$RUN_TESTS_SH" --detect-runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "junit" ]
}

@test "AC3: detect_runner — pytest via pyproject.toml" {
  proj="$TEST_TMP/proj-pytest"
  mkdir -p "$proj"
  cat > "$proj/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
  run "$RUN_TESTS_SH" --detect-runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "pytest" ]
}

@test "AC3: detect_runner — pytest via pytest.ini" {
  proj="$TEST_TMP/proj-pytest-ini"
  mkdir -p "$proj"
  : > "$proj/pytest.ini"
  run "$RUN_TESTS_SH" --detect-runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "pytest" ]
}

@test "AC3: detect_runner — Go via go.mod" {
  proj="$TEST_TMP/proj-go"
  mkdir -p "$proj"
  : > "$proj/go.mod"
  run "$RUN_TESTS_SH" --detect-runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "go" ]
}

@test "AC3: detect_runner — Maestro via .maestro/" {
  proj="$TEST_TMP/proj-maestro"
  mkdir -p "$proj/.maestro"
  : > "$proj/.maestro/flow.yaml"
  run "$RUN_TESTS_SH" --detect-runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "maestro" ]
}

@test "AC3: detect_runner — unknown stack returns non-zero with clear error" {
  proj="$TEST_TMP/proj-unknown"
  mkdir -p "$proj"
  run "$RUN_TESTS_SH" --detect-runner "$proj"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no runner detected"* ]] || [[ "$output" == *"unknown"* ]]
}

# --- AC4: bridge-contract identity --------------------------------------

@test "AC4: bridge contract — exit 0 + suites[] when test_execution absent (graceful skip)" {
  cfg="$TEST_TMP/project-config.yaml"
  cat > "$cfg" <<EOF
project_root: ${TEST_TMP}
framework_version: "1.134.1"
EOF
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story-key "E67-S6" --context "local"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"suites"'* ]]
}

# --- Tier alias mapping --------------------------------------------------

@test "tier alias: integration -> tier_2" {
  cfg="$TEST_TMP/project-config.yaml"
  cat > "$cfg" <<EOF
project_root: ${TEST_TMP}
framework_version: "1.134.1"
test_execution:
  tier_2:
    placement: local
    command: "echo TIER2_RAN > $TEST_TMP/sentinel"
    timeout_seconds: 30
EOF
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story "E67-S6" --tier "integration"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/sentinel" ]
  grep -q "TIER2_RAN" "$TEST_TMP/sentinel"
}

@test "tier alias: e2e -> tier_3" {
  cfg="$TEST_TMP/project-config.yaml"
  cat > "$cfg" <<EOF
project_root: ${TEST_TMP}
framework_version: "1.134.1"
test_execution:
  tier_3:
    placement: local
    command: "echo TIER3_RAN > $TEST_TMP/sentinel"
    timeout_seconds: 30
EOF
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story "E67-S6" --tier "e2e"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/sentinel" ]
  grep -q "TIER3_RAN" "$TEST_TMP/sentinel"
}
