#!/usr/bin/env bats
# adapters/gitleaks/test/contract.bats — ADR-078 adapter parity (E66-S2, NFR-RSV2-11).
# Project-scope adapter — not_applicable triggers on empty file-list.

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "gitleaks contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "gitleaks contract: state=available when tool on PATH and file-list non-empty" {
  # Project-scope: use any extension. The probe sees an empty extension list and applies.
  assert_state "$(_contract_provider)" available ".any" 0 "" 0
  assert_fragment_shape
}

@test "gitleaks contract: state=expected_and_missing when tool absent from PATH" {
  assert_state "$(_contract_provider)" expected_and_missing ".any" 0 "" 0
  assert_fragment_shape
}

@test "gitleaks contract: state=ran_and_errored when run.sh exits non-zero" {
  assert_state "$(_contract_provider)" ran_and_errored ".any" 1 "leak detection failed" 0
  assert_fragment_shape
}

@test "gitleaks contract: state=not_applicable when file-list is empty" {
  assert_state "$(_contract_provider)" not_applicable EMPTY_FILE_LIST 0 "" 0
  assert_fragment_shape
}
