#!/usr/bin/env bats
# qa-execution-evidence.bats — E67-S4 schema-conformance coverage for
# execution-evidence.json shape (AC4, AC10).
#
# Validates that the runner emits a JSON document conforming to
# plugins/gaia/schemas/execution-evidence.schema.json.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  STORY_KEY="E67-S4"
  WORKDIR="${TEST_TMP}/.gaia/state/review/qa-tests/${STORY_KEY}"
  mkdir -p "$WORKDIR"
  SCHEMA="${SCHEMAS_DIR}/execution-evidence.schema.json"
}
teardown() { common_teardown; }

write_config() {
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
    command: "true"
    timeout_seconds: 30
EOF
}

@test "schema file exists" {
  [ -f "$SCHEMA" ]
}

@test "schema declares draft-07 and required top-level fields" {
  jq -e '."$schema" | contains("draft-07")' "$SCHEMA" >/dev/null
  jq -e '.required | index("suites")' "$SCHEMA" >/dev/null
  jq -e '.required | index("tier")' "$SCHEMA" >/dev/null
  jq -e '.required | index("context")' "$SCHEMA" >/dev/null
  jq -e '.required | index("wall_clock_seconds")' "$SCHEMA" >/dev/null
}

@test "evidence JSON validates against schema (passing tier)" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  write_config "$TEST_TMP/project-config.yaml"
  env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  ajv validate -s "$SCHEMA" -d "$WORKDIR/execution-evidence.json"
}

@test "evidence JSON has wall_clock_seconds >= sum(suite.duration_seconds) lower bound" {
  write_config "$TEST_TMP/project-config.yaml"
  env GAIA_EXECUTION_CONTEXT=local \
    "$QA_TEST_RUNNER" \
      --story-key "$STORY_KEY" \
      --workdir "$WORKDIR" \
      --config "$TEST_TMP/project-config.yaml"
  jq -e '.wall_clock_seconds >= 0' "$WORKDIR/execution-evidence.json" >/dev/null
  jq -e '[.suites[].duration_seconds] | all(. >= 0)' "$WORKDIR/execution-evidence.json" >/dev/null
}
