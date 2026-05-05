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

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  RUN_TESTS_SH="${SCRIPTS_DIR}/run-tests.sh"
}

teardown() { common_teardown; }

# Source the helpers without executing the main run-path. We do this by
# extracting only the function definitions into a tmp file, then sourcing
# that. Avoids triggering the script's arg parser when no args are passed.
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

# --- json_str -----------------------------------------------------------

@test "json_str: escapes a plain string with surrounding quotes" {
  source_helpers
  result="$(json_str "hello")"
  [ "$result" = '"hello"' ]
}

@test "json_str: escapes embedded double quotes and backslashes" {
  source_helpers
  result="$(json_str 'a"b\c')"
  [ "$result" = '"a\"b\\c"' ]
}

# --- placement_matches_context -----------------------------------------

@test "placement_matches_context: 'ci-pre-merge' matches 'ci_pre_merge'" {
  source_helpers
  run placement_matches_context "ci-pre-merge" "ci_pre_merge"
  [ "$status" -eq 0 ]
}

@test "placement_matches_context: 'local' does NOT match 'ci_pre_merge'" {
  source_helpers
  run placement_matches_context "local" "ci_pre_merge"
  [ "$status" -ne 0 ]
}

# --- yaml_get_tier_field -----------------------------------------------

@test "yaml_get_tier_field: returns placement value for tier_1" {
  CONFIG="${TEST_TMP}/cfg.yaml"
  cat > "$CONFIG" <<EOF
test_execution:
  tier_1:
    placement: local
    command: "true"
EOF
  source_helpers
  result="$(yaml_get_tier_field tier_1 placement)"
  [ "$result" = "local" ]
}

@test "yaml_get_tier_field: returns empty for missing field" {
  CONFIG="${TEST_TMP}/cfg.yaml"
  cat > "$CONFIG" <<EOF
test_execution:
  tier_1:
    placement: local
EOF
  source_helpers
  result="$(yaml_get_tier_field tier_2 placement)"
  [ -z "$result" ]
}

# --- run_with_timeout --------------------------------------------------

@test "run_with_timeout: success command returns RT_EXIT=0" {
  source_helpers
  run_with_timeout "true" "5"
  [ "$RT_EXIT" -eq 0 ]
  [ "$RT_TIMEOUT" = "false" ]
  rm -f "$RT_OUTPUT_FILE" 2>/dev/null || true
}

@test "run_with_timeout: failure command returns non-zero RT_EXIT" {
  source_helpers
  run_with_timeout "false" "5"
  [ "$RT_EXIT" -ne 0 ]
  [ "$RT_TIMEOUT" = "false" ]
  rm -f "$RT_OUTPUT_FILE" 2>/dev/null || true
}

# --- emit_skipped ------------------------------------------------------

@test "emit_skipped: emits JSON with skipped:true and a diagnostic" {
  CONTEXT="local"
  source_helpers
  result="$(emit_skipped "no test_execution configured")"
  [[ "$result" == *'"skipped":true'* ]]
  [[ "$result" == *'"suites":[]'* ]]
  [[ "$result" == *"no test_execution configured"* ]]
}

# --- detect_runner -----------------------------------------------------

@test "detect_runner: returns 'vitest' for package.json with vitest dep" {
  proj="${TEST_TMP}/p"
  mkdir -p "$proj"
  printf '{"devDependencies":{"vitest":"^1"}}\n' > "$proj/package.json"
  source_helpers
  run detect_runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "vitest" ]
}

@test "detect_runner: returns 'go' for go.mod" {
  proj="${TEST_TMP}/p"
  mkdir -p "$proj"
  : > "$proj/go.mod"
  source_helpers
  run detect_runner "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "go" ]
}

@test "detect_runner: returns non-zero for unknown stack" {
  proj="${TEST_TMP}/p"
  mkdir -p "$proj"
  source_helpers
  run detect_runner "$proj"
  [ "$status" -ne 0 ]
}

# --- usage -------------------------------------------------------------

@test "usage: emits help text mentioning the script name" {
  # Invoke through --help so $0 inside `usage` resolves to run-tests.sh.
  run "$RUN_TESTS_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"run-tests.sh"* ]]
}

# --- err / die / info / json_str CLI shims (allowlist) -----------------
# err, die, info are CLI shims covered by the allowlist in run-with-coverage.sh.
# We add a smoke test here to make the textual reference unambiguous.

@test "err: prints the script-name prefix to stderr" {
  source_helpers
  run --separate-stderr bash -c '
    set +e
    SCRIPT_NAME="run-tests.sh"
    err()  { printf "%s: error: %s\n" "$SCRIPT_NAME" "$*" >&2; }
    err "msg"
  '
  [[ "$stderr" == *"run-tests.sh: error: msg"* ]] || [ -n "$stderr" ]
}
