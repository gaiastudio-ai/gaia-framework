#!/usr/bin/env bats
# adapters/owasp-dependency-check/test/contract.bats — ADR-078 adapter parity (E66-S2, NFR-RSV2-11).
# E70-S4: OWASP Dependency-Check adapter as alternative dep-audit under runtime-profile: container.
#
# Exercises all four probe states: available, expected_and_missing, ran_and_errored,
# not_applicable. Because adapter.json declares runtime-profile: container, the
# expected_and_missing test passes --runtime-profile subprocess to force the probe's
# provider-binary check (the container branch checks docker, not the provider).
# This mirrors the E70-S3 sonarqube precedent — no new probe logic is introduced;
# tests exercise the existing four-state probe override surface.

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "owasp-dependency-check contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "owasp-dependency-check contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    # Project-scope adapter (file-extensions: []) — non-empty file list is the trigger.
    assert_state "$(_contract_provider)" available "src/example.txt" 0 "" 0 \
      --runtime-profile subprocess
  else
    assert_state "$(_contract_provider)" available "$ext" 0 "" 0 \
      --runtime-profile subprocess
  fi
  assert_fragment_shape
}

@test "owasp-dependency-check contract: state=expected_and_missing when provider absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    assert_state "$(_contract_provider)" expected_and_missing "src/example.txt" 0 "" 0 \
      --runtime-profile subprocess
  else
    assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0 \
      --runtime-profile subprocess
  fi
  assert_fragment_shape
}

@test "owasp-dependency-check contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    assert_state "$(_contract_provider)" ran_and_errored "src/example.txt" 1 "owasp dc crash" 0 \
      --runtime-profile subprocess
  else
    assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "owasp dc crash" 0 \
      --runtime-profile subprocess
  fi
  assert_fragment_shape
}

@test "owasp-dependency-check contract: state=not_applicable when file-list is empty (project-scope)" {
  assert_state "$(_contract_provider)" not_applicable "EMPTY_FILE_LIST" 0 "" 0 \
    --runtime-profile subprocess
  assert_fragment_shape
}

@test "owasp-dependency-check contract: adapter.json declares runtime-profile=container (AC1)" {
  local rp
  rp="$(jq -r '."runtime-profile" // ""' "$ADAPTER_DIR/adapter.json")"
  [ "$rp" = "container" ]
}

@test "owasp-dependency-check contract: adapter.json declares category=dep-audit (AC1)" {
  local cat
  cat="$(jq -r '.category // ""' "$ADAPTER_DIR/adapter.json")"
  [ "$cat" = "dep-audit" ]
}

@test "owasp-dependency-check contract: adapter.json declares provider=owasp-dependency-check (AC1)" {
  local prov
  prov="$(jq -r '.provider // ""' "$ADAPTER_DIR/adapter.json")"
  [ "$prov" = "owasp-dependency-check" ]
}

@test "owasp-dependency-check contract: adapter.json declares default-timeout-seconds (AC1)" {
  local t
  t="$(jq -r '."default-timeout-seconds" // ""' "$ADAPTER_DIR/adapter.json")"
  [ -n "$t" ] && [ "$t" -ge 1 ]
}

@test "owasp-dependency-check contract: adapter.json declares non-empty version-range (AC1)" {
  local v
  v="$(jq -r '."version-range" // ""' "$ADAPTER_DIR/adapter.json")"
  [ -n "$v" ]
}
