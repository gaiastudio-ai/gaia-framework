#!/usr/bin/env bats
# adapters/gosec/test/contract.bats — adapter parity for the gosec Go SAST adapter.
# Exercises all four probe states: available, expected_and_missing,
# ran_and_errored, not_applicable. Mirrors the sibling semgrep/sonarqube
# contract tests; the generic helper drives state from this adapter's own
# adapter.json (provider=gosec, file-extensions=[.go]).

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "gosec contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "gosec contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "gosec contract: state=expected_and_missing when tool absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "gosec contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "scanner crash" 0
  assert_fragment_shape
}

@test "gosec contract: state=not_applicable when file-list has no matching extensions" {
  assert_state "$(_contract_provider)" not_applicable "" 0 "" 0
  assert_fragment_shape
}

@test "gosec contract: first file-extension is .go" {
  [ "$(_contract_first_ext)" = ".go" ]
}

@test "gosec contract: tool-absent run exits 127 with an install hint" {
  flist="$BATS_TEST_TMPDIR/flist.txt"
  printf 'main.go\n' > "$flist"
  run env PATH="/usr/bin:/bin" bash "$BATS_TEST_DIRNAME/../run.sh" --input "$flist"
  [ "$status" -eq 127 ]
  [[ "$output" == *"gosec not found on PATH"* ]]
  [[ "$output" == *"install via"* ]]
}
