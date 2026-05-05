#!/usr/bin/env bats
# probe-state-to-check-status.bats — unit tests for
# plugins/gaia/scripts/review-common/probe-state-to-check-status.sh (E70-S6).
#
# Covers TC-RSV2-PSTC-01..04, AC1..AC3.
#
# The helper maps a probe state (one of: available, expected_and_missing,
# ran_and_errored, not_applicable) to the corresponding analysis-results.json
# check.status enum (one of: passed, errored, skipped). Canonical mapping per
# plugins/gaia/scripts/adapters/BOUNDARIES.md §Three-State Availability Probe
# and plugins/gaia/scripts/adapters/_schema/run-contract.md §5.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  HELPER="$SCRIPTS_DIR/review-common/probe-state-to-check-status.sh"
}
teardown() { common_teardown; }

# --- AC1: canonical four-way mapping ---

@test "probe-state-to-check-status: available -> passed" {
  run "$HELPER" --probe-state available
  [ "$status" -eq 0 ]
  [ "$output" = "passed" ]
}

@test "probe-state-to-check-status: expected_and_missing -> errored" {
  run "$HELPER" --probe-state expected_and_missing
  [ "$status" -eq 0 ]
  [ "$output" = "errored" ]
}

@test "probe-state-to-check-status: ran_and_errored -> errored" {
  run "$HELPER" --probe-state ran_and_errored
  [ "$status" -eq 0 ]
  [ "$output" = "errored" ]
}

@test "probe-state-to-check-status: not_applicable -> skipped" {
  run "$HELPER" --probe-state not_applicable
  [ "$status" -eq 0 ]
  [ "$output" = "skipped" ]
}

# --- AC2: unknown state ---

@test "probe-state-to-check-status: unknown state exits 1 with diagnostic" {
  run --separate-stderr "$HELPER" --probe-state bogus_state
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"bogus_state"* ]]
  [[ "$stderr" == *"available"* ]]
  [[ "$stderr" == *"expected_and_missing"* ]]
  [[ "$stderr" == *"ran_and_errored"* ]]
  [[ "$stderr" == *"not_applicable"* ]]
}

# --- AC3: CLI surface ---

@test "probe-state-to-check-status: missing --probe-state flag exits 1" {
  run --separate-stderr "$HELPER"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--probe-state"* ]]
}

@test "probe-state-to-check-status: --probe-state without value exits 1" {
  run "$HELPER" --probe-state
  [ "$status" -eq 1 ]
}

@test "probe-state-to-check-status: --help exits 0 with usage on stdout" {
  run "$HELPER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe-state-to-check-status.sh"* ]]
  [[ "$output" == *"--probe-state"* ]]
}

@test "probe-state-to-check-status: unknown flag exits 1" {
  run "$HELPER" --bogus-flag
  [ "$status" -eq 1 ]
}
