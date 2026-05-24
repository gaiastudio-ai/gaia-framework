#!/usr/bin/env bats
# qa-test-runner.bats — E67-S4 bats coverage for qa-test-runner.sh.
# Refs: AC3 (tier placement), AC4 (evidence capture), AC5 (failure verdict),
#       AC6 (timeout), AC7 (graceful skip), AC10 (POSIX/bash 3.2).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  STORY_KEY="E67-S4"
  WORKDIR="${TEST_TMP}/.gaia/state/review/qa-tests/${STORY_KEY}"
  mkdir -p "$WORKDIR"
}
teardown() { common_teardown; }

# --- helpers -----------------------------------------------------------

write_config() {
  # write_config <path> <tier1_placement> <tier2_placement> <tier3_placement>
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: ${2:-local}
    command: "true"
    timeout_seconds: 30
  tier_2:
    placement: ${3:-ci-pre-merge}
    command: "true"
    timeout_seconds: 60
  tier_3:
    placement: ${4:-ci-post-merge}
    command: "true"
    timeout_seconds: 120
EOF
}

write_failing_command_config() {
  # tier_1.placement=local, tier_1.command exits non-zero
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "false"
    timeout_seconds: 30
EOF
}

write_timeout_command_config() {
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
test_execution:
  tier_1:
    placement: local
    command: "sleep 30"
    timeout_seconds: 1
EOF
}

write_minimal_config_no_test_exec() {
  cat > "$1" <<EOF
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
memory_path: ${TEST_TMP}/_memory
checkpoint_path: ${TEST_TMP}/_memory/checkpoints
installed_path: ${TEST_TMP}
framework_version: "1.134.1"
date: "2026-05-05"
EOF
}

# --- AC10: script exists and is executable -----------------------------

@test "AC10: qa-test-runner.sh exists and is executable" {
  [ -f "$QA_TEST_RUNNER" ]
  [ -x "$QA_TEST_RUNNER" ]
}

@test "AC10: --help prints usage and exits 0" {
  run --separate-stderr "$QA_TEST_RUNNER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--story-key"* ]]
  [[ "$output" == *"--workdir"* ]]
}

# --- AC3: tier resolution from GAIA_EXECUTION_CONTEXT -------------------

@test "AC3: local context runs tier_1 only when tier_1.placement=local" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/execution-evidence.json" ]
  jq -e '.suites | length == 1' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].name == "tier_1"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.context == "local"' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "AC3: ci_pre_merge context runs tier_2 only when tier_2.placement=ci-pre-merge" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=ci_pre_merge \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.suites | length == 1' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].name == "tier_2"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.context == "ci_pre_merge"' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "AC3: ci_pre_merge context runs both tier_1 and tier_2 if both placements match" {
  # When tier_1.placement and tier_2.placement both equal ci-pre-merge.
  write_config "$TEST_TMP/project-config.yaml" ci-pre-merge ci-pre-merge ci-post-merge
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=ci_pre_merge \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.suites | length == 2' "$WORKDIR/execution-evidence.json" >/dev/null
}

@test "AC3: default context is local when GAIA_EXECUTION_CONTEXT is unset" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr env -u GAIA_EXECUTION_CONTEXT \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.context == "local"' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- AC4: execution evidence capture -----------------------------------

@test "AC4: execution-evidence.json contains required fields" {
  write_config "$TEST_TMP/project-config.yaml" local ci-pre-merge ci-post-merge
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.tier' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.context' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.wall_clock_seconds | type == "number"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].name' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].command' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].exit_code | type == "number"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].duration_seconds | type == "number"' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0] | has("pass_count") and has("fail_count")' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- AC5: required test failure -- runner exits non-zero ----------------

@test "AC5: tier_1 command failure produces evidence with exit_code != 0" {
  write_failing_command_config "$TEST_TMP/project-config.yaml"
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  # Runner itself returns 0 (evidence capture is its responsibility); the
  # verdict is derived later by verdict-resolver from the evidence.
  [ "$status" -eq 0 ]
  jq -e '.suites[0].exit_code != 0' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].timeout == false' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- AC6: timeout handling --------------------------------------------

@test "AC6: tier_1 command exceeding timeout_seconds is killed and recorded" {
  write_timeout_command_config "$TEST_TMP/project-config.yaml"
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  jq -e '.suites[0].timeout == true' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites[0].duration_seconds | . < 5' "$WORKDIR/execution-evidence.json" >/dev/null
}

# --- AC7: graceful skip when test_execution absent ---------------------

@test "AC7: missing test_execution section -- skipped with INFO diagnostic" {
  write_minimal_config_no_test_exec "$TEST_TMP/project-config.yaml"
  run --separate-stderr env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/execution-evidence.json" ]
  jq -e '.skipped == true' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '.suites | length == 0' "$WORKDIR/execution-evidence.json" >/dev/null
  [[ "$stderr" == *"test_execution not configured"* ]] || \
    [[ "$stderr" == *"INFO"* ]]
}

# --- AC10: required-flag handling --------------------------------------

@test "AC10: missing --story-key fails fast" {
  run --separate-stderr "$QA_TEST_RUNNER" --workdir "$WORKDIR"
  [ "$status" -ne 0 ]
}

@test "AC10: missing --workdir fails fast" {
  run --separate-stderr "$QA_TEST_RUNNER" --story-key "$STORY_KEY"
  [ "$status" -ne 0 ]
}
