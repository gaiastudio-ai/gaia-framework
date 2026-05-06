#!/usr/bin/env bats
# run-tests.bats — E67-S6 unit-level coverage for run-tests.sh public
# functions, satisfying the NFR-052 public-function-coverage gate.
#
# The story-level contract suite lives at
# plugins/gaia/scripts/test/run-tests-contract.bats per AC3 (story-mandated
# path). This file is the NFR-052-required mirror under plugins/gaia/tests/
# and exercises each public function by name:
#
#   detect_runner, emit_skipped, json_str, placement_matches_context,
#   run_with_timeout, yaml_get_tier_field, usage
#
# Refs: AC1, AC2, AC3, AC5, NFR-052.
#
# CI time-budget note: the bats-tests CI job has a 5-minute hard timeout
# (plugin-ci.yml). Keep this suite tight — defer comprehensive end-to-end
# coverage to the contract suite at plugins/gaia/scripts/test/.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  RUN_TESTS_SH="${SCRIPTS_DIR}/run-tests.sh"
}

teardown() { common_teardown; }

# Source the helpers without executing the main run-path. Extract function
# definitions only, then source them in the test-process so each function
# name is referenced textually for NFR-052 coverage AND callable directly.
source_helpers() {
  local out="${TEST_TMP}/helpers.sh"
  awk '
    /^[a-z_][a-z0-9_]*\(\)[[:space:]]*\{/ { in_fn=1 }
    in_fn { print }
    in_fn && /^\}/ { in_fn=0 }
  ' "$RUN_TESTS_SH" > "$out"
  # shellcheck source=/dev/null
  . "$out"
}

@test "json_str + placement_matches_context: round-trip and matcher" {
  source_helpers
  result="$(json_str "hi")"
  [ "$result" = '"hi"' ]
  run placement_matches_context "ci-pre-merge" "ci_pre_merge"
  [ "$status" -eq 0 ]
  run placement_matches_context "local" "ci_pre_merge"
  [ "$status" -ne 0 ]
}

@test "yaml_get_tier_field + emit_skipped: read placement, emit skip JSON" {
  CONFIG="${TEST_TMP}/cfg.yaml"
  cat > "$CONFIG" <<EOF
test_execution:
  tier_1:
    placement: local
    command: "true"
EOF
  CONTEXT="local"
  source_helpers
  result="$(yaml_get_tier_field tier_1 placement)"
  [ "$result" = "local" ]
  json="$(emit_skipped "no test_execution configured")"
  [[ "$json" == *'"skipped":true'* ]]
  [[ "$json" == *'"suites":[]'* ]]
}

@test "detect_runner + run_with_timeout: stack signature + cmd timeout helper" {
  proj="${TEST_TMP}/p"
  mkdir -p "$proj"
  : > "$proj/go.mod"
  source_helpers
  run detect_runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "go" ]
  run_with_timeout "true" "5"
  [ "$RT_EXIT" -eq 0 ]
  [ "$RT_TIMEOUT" = "false" ]
  rm -f "$RT_OUTPUT_FILE" 2>/dev/null || true
}

@test "usage: --help emits FR-RSV2-19 adapter-contract documentation" {
  run "$RUN_TESTS_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"run-tests.sh"* ]]
  [[ "$output" == *"--story-key"* ]] || [[ "$output" == *"--story"* ]]
}
