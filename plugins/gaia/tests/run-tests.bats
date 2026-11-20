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

# ---------------------------------------------------------------------------
# Helpers for end-to-end parser tests
# ---------------------------------------------------------------------------

# Write a minimal project-config.yaml with a tier_1 command.
_write_test_config() {
  local cfg="$1" cmd="$2"
  cat > "$cfg" <<YAML
project_root: ${TEST_TMP}
project_path: ${TEST_TMP}
framework_version: "1.0.0"
test_execution:
  tier_1:
    placement: local
    command: "${cmd}"
    timeout_seconds: 30
YAML
}

# ---------------------------------------------------------------------------
# TAP precedence and output-preservation tests
# ---------------------------------------------------------------------------

@test "TAP output parsed by TAP counter, not pytest regex, for 500 green tests" {
  # Build a TAP fixture with 500 ok lines. Some test names contain trigger
  # tokens like "N passed" that the pytest regex would match if it ran first.
  fixture="${TEST_TMP}/tap-500.txt"
  {
    printf '1..500\n'
    for i in $(seq 1 500); do
      case "$((i % 5))" in
        0) printf 'ok %d flow 3 passed boundary\n' "$i" ;;
        1) printf 'ok %d handles 5 passed items\n' "$i" ;;
        2) printf 'ok %d verifies 7 passed records\n' "$i" ;;
        3) printf 'ok %d retries succeed on attempt 2 passed\n' "$i" ;;
        *) printf 'ok %d basic sanity check\n' "$i" ;;
      esac
    done
  } > "$fixture"
  cfg="${TEST_TMP}/cfg.yaml"
  _write_test_config "$cfg" "cat ${fixture}"
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story-key "E1-S1" --context "local"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  [ "$status" -eq 0 ]
  # The TAP parser must count 500 ok lines, not the pytest regex's last
  # "N passed" match from a test name.
  [[ "$output" == *'"pass_count":500'* ]]
  [[ "$output" == *'"fail_count":0'* ]]
}

@test "TAP mixed output: 498 passed and 2 failed with trigger tokens" {
  fixture="${TEST_TMP}/tap-mixed.txt"
  {
    printf '1..500\n'
    for i in $(seq 1 498); do
      case "$((i % 3))" in
        0) printf 'ok %d flow 3 passed boundary\n' "$i" ;;
        1) printf 'ok %d handles 5 passed items\n' "$i" ;;
        *) printf 'ok %d basic check\n' "$i" ;;
      esac
    done
    printf 'not ok 499 retries 2 failed calls\n'
    printf 'not ok 500 timeout after 3 failed attempts\n'
  } > "$fixture"
  cfg="${TEST_TMP}/cfg.yaml"
  _write_test_config "$cfg" "cat ${fixture}"
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story-key "E1-S1" --context "local"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  [ "$status" -eq 0 ]
  [[ "$output" == *'"pass_count":498'* ]]
  [[ "$output" == *'"fail_count":2'* ]]
}

@test "raw bats output file preserved after parsing (not deleted)" {
  # Point TMPDIR at a fresh directory so we can find the output file.
  raw_dir="${TEST_TMP}/raw-output"
  mkdir -p "$raw_dir"
  cfg="${TEST_TMP}/cfg.yaml"
  _write_test_config "$cfg" "printf 'ok 1 basic test\n'"
  run env TMPDIR="$raw_dir" GAIA_TESTS_CONFIG="$cfg" \
    "$RUN_TESTS_SH" --context "local" --story-key "E1-S1"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  [ "$status" -eq 0 ]
  # The raw output file must still exist in the TMPDIR directory.
  local file_count
  file_count="$(find "$raw_dir" -type f | wc -l)"
  [ "$file_count" -gt 0 ]
  # And it must contain the raw TAP output.
  grep -q 'ok 1 basic test' "$raw_dir"/* 2>/dev/null
}

@test "pytest summary parsed correctly when output has no TAP lines" {
  # Pytest fixture with a mid-line "ok" token to verify TAP regex does not
  # false-positive, plus the standard summary line.
  fixture="${TEST_TMP}/pytest-out.txt"
  cat > "$fixture" <<'PYTEST'
tests/test_ok_handler.py::test_ok_response PASSED
tests/test_ok_handler.py::test_ok_timeout FAILED
tests/test_retry.py::test_basic PASSED
tests/test_retry.py::test_edge PASSED
tests/test_retry.py::test_boundary PASSED
===== 5 passed, 1 failed in 0.18s =====
PYTEST
  cfg="${TEST_TMP}/cfg.yaml"
  _write_test_config "$cfg" "cat ${fixture}"
  run env GAIA_TESTS_CONFIG="$cfg" "$RUN_TESTS_SH" --story-key "E1-S1" --context "local"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  [ "$status" -eq 0 ]
  [[ "$output" == *'"pass_count":5'* ]]
  [[ "$output" == *'"fail_count":1'* ]]
}

@test "TAP line regex matches TAP but not pytest or go-test output" {
  # Verify the TAP detection regex in isolation against three output shapes.
  tap_fixture="${TEST_TMP}/tap.txt"
  cat > "$tap_fixture" <<'TAP'
1..3
ok 1 first test
ok 2 second test
not ok 3 third test
TAP
  pytest_fixture="${TEST_TMP}/pytest.txt"
  cat > "$pytest_fixture" <<'PY'
tests/test_ok_handler.py::test_ok_response PASSED
===== 5 passed, 1 failed in 0.18s =====
PY
  go_fixture="${TEST_TMP}/gotest.txt"
  # go-test uses tabs, not spaces, after "ok"
  printf '=== RUN   TestFoo\n--- PASS: TestFoo (0.00s)\nPASS\nok\tmypkg\t0.001s\n' > "$go_fixture"

  # TAP fixture: must match
  local tap_ok tap_notok
  tap_ok="$(grep -cE '^ok [0-9]+' "$tap_fixture" 2>/dev/null || true)"
  tap_notok="$(grep -cE '^not ok [0-9]+' "$tap_fixture" 2>/dev/null || true)"
  [ "$tap_ok" -eq 2 ]
  [ "$tap_notok" -eq 1 ]

  # pytest fixture: must NOT match
  local py_ok py_notok
  py_ok="$(grep -cE '^ok [0-9]+' "$pytest_fixture" 2>/dev/null || true)"
  py_notok="$(grep -cE '^not ok [0-9]+' "$pytest_fixture" 2>/dev/null || true)"
  [ "${py_ok:-0}" -eq 0 ]
  [ "${py_notok:-0}" -eq 0 ]

  # go-test fixture: must NOT match (tab after "ok", not space)
  local go_ok go_notok
  go_ok="$(grep -cE '^ok [0-9]+' "$go_fixture" 2>/dev/null || true)"
  go_notok="$(grep -cE '^not ok [0-9]+' "$go_fixture" 2>/dev/null || true)"
  [ "${go_ok:-0}" -eq 0 ]
  [ "${go_notok:-0}" -eq 0 ]
}
