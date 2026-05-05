#!/usr/bin/env bats
# _schema/test/contract.bats — canonical four-state probe parity template.
#
# Story: E70-S1 — Adapter pattern formalization.
# Decisions: ADR-078 (Tool Adapter Framework), NFR-RSV2-11 (parity test).
#
# Usage: copy this file into a new adapter at
#   plugins/gaia/scripts/adapters/{tool}/test/contract.bats
# and rename the @test descriptors from "adapter contract:" to
# "{tool} contract:" — no other edits required. The helper reads provider
# and the first file-extension from the adapter's adapter.json at runtime,
# so the template is generic.
#
# This template is itself a valid bats file and is exercised by
# plugins/gaia/tests/adapter-schema-contract.bats (AC3) which checks for
# the four states and the canonical assertions.

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "adapter contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "adapter contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "adapter contract: state=expected_and_missing when tool absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "adapter contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "adapter crash" 0
  assert_fragment_shape
}

@test "adapter contract: state=not_applicable when file-list has no matching extensions" {
  assert_state "$(_contract_provider)" not_applicable "" 0 "" 0
  assert_fragment_shape
}
