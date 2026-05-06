#!/usr/bin/env bats
# adapters/k6/test/contract.bats — ADR-078 adapter parity (E73-S2).
# Exercises all four probe states: available, expected_and_missing, ran_and_errored, not_applicable.

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "k6 contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "k6 contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    ext=".js"
  fi
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "k6 contract: state=expected_and_missing when tool absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    ext=".js"
  fi
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "k6 contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    ext=".js"
  fi
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "k6 crashed" 0
  assert_fragment_shape
}

@test "k6 contract: state=not_applicable when file-list has no matching extensions" {
  assert_state "$(_contract_provider)" not_applicable "EMPTY_FILE_LIST" 0 "" 0
  assert_fragment_shape
}
