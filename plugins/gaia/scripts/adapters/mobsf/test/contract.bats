#!/usr/bin/env bats
# adapters/mobsf/test/contract.bats — E74-S7 mobile-static adapter parity (ADR-078, NFR-RSV2-11).
# Exercises all four probe states: available, expected_and_missing, ran_and_errored, not_applicable.

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "mobsf contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "mobsf contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "mobsf contract: state=expected_and_missing when tool absent from PATH" {
  # MobSF declares runtime-profile: network — tool-availability-probe.sh
  # explicitly skips the binary check for the network profile (the remote
  # service URL is the availability surface, not local PATH). The
  # expected_and_missing state is therefore unreachable for this adapter and
  # the helper's mutation cannot synthesize it. Skip per ADR-078 §5.
  skip "network runtime-profile bypasses local PATH check (ADR-078 §5)"
}

@test "mobsf contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "scanner crash" 0
  assert_fragment_shape
}

@test "mobsf contract: state=not_applicable when file-list has no matching extensions" {
  assert_state "$(_contract_provider)" not_applicable "" 0 "" 0
  assert_fragment_shape
}
