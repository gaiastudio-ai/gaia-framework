#!/usr/bin/env bats
# adapters/cypress-e2e/test/contract.bats — ADR-078 adapter parity (E73-S1).
# Exercises all four probe states: available, expected_and_missing, ran_and_errored, not_applicable.

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "cypress-e2e contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "cypress-e2e contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    ext=".cy.ts"
  fi
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "cypress-e2e contract: state=expected_and_missing when tool absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    ext=".cy.ts"
  fi
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "cypress-e2e contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    ext=".cy.ts"
  fi
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "cypress crash" 0
  assert_fragment_shape
}

@test "cypress-e2e contract: state=not_applicable when file-list has no matching extensions" {
  assert_state "$(_contract_provider)" not_applicable "EMPTY_FILE_LIST" 0 "" 0
  assert_fragment_shape
}
