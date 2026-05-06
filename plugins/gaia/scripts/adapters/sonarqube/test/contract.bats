#!/usr/bin/env bats
# adapters/sonarqube/test/contract.bats — ADR-078 adapter parity (E66-S2, NFR-RSV2-11).
# E70-S3: SonarQube adapter as alternative SAST under runtime-profile: container.
#
# Exercises all four probe states: available, expected_and_missing, ran_and_errored,
# not_applicable. Because adapter.json declares runtime-profile: container, the
# expected_and_missing test passes --runtime-profile subprocess to force the probe's
# provider-binary check (the container branch checks docker, not the provider).
# Per E70-S3 Dev Notes, no new probe logic is introduced; tests use the existing
# probe override surface.

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "sonarqube contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "sonarqube contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0 \
    --runtime-profile subprocess
  assert_fragment_shape
}

@test "sonarqube contract: state=expected_and_missing when sonar-scanner absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0 \
    --runtime-profile subprocess
  assert_fragment_shape
}

@test "sonarqube contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "sonar-scanner crash" 0 \
    --runtime-profile subprocess
  assert_fragment_shape
}

@test "sonarqube contract: state=not_applicable when file-list has no matching extensions" {
  assert_state "$(_contract_provider)" not_applicable "" 0 "" 0 \
    --runtime-profile subprocess
  assert_fragment_shape
}

@test "sonarqube contract: adapter.json declares runtime-profile=container (AC2)" {
  local rp
  rp="$(jq -r '."runtime-profile" // ""' "$ADAPTER_DIR/adapter.json")"
  [ "$rp" = "container" ]
}

@test "sonarqube contract: adapter.json declares category=sast (AC2)" {
  local cat
  cat="$(jq -r '.category // ""' "$ADAPTER_DIR/adapter.json")"
  [ "$cat" = "sast" ]
}

@test "sonarqube contract: adapter.json declares provider=sonar-scanner" {
  local prov
  prov="$(jq -r '.provider // ""' "$ADAPTER_DIR/adapter.json")"
  [ "$prov" = "sonar-scanner" ]
}
