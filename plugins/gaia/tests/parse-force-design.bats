#!/usr/bin/env bats
# parse-force-design.bats — tests for the shared --force-design flag parser.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup
  PARSER="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)/parse-force-design.sh"
}

teardown() { common_teardown; }

@test "parse-force-design.sh exists and is executable" {
  [ -f "$PARSER" ]
  [ -x "$PARSER" ]
}

@test "all four flags are parsed and exported" {
  source "$PARSER"
  _parse_force_design --force-design --reason "test reason text" --entry-point gaia-create-arch --sprint-id sprint-82
  [ "$FORCE_DESIGN" = "1" ]
  [ "$FORCE_DESIGN_REASON" = "test reason text" ]
  [ "$FORCE_DESIGN_ENTRY_POINT" = "gaia-create-arch" ]
  [ "$FORCE_DESIGN_SPRINT_ID" = "sprint-82" ]
}

@test "unrelated flags pass through to _PFD_REMAINING" {
  source "$PARSER"
  _parse_force_design --force-design --reason "r" --bypass gaia-threat-model --unknown-flag
  [ "$FORCE_DESIGN" = "1" ]
  [ "${#_PFD_REMAINING[@]}" -eq 3 ]
  [ "${_PFD_REMAINING[0]}" = "--bypass" ]
  [ "${_PFD_REMAINING[1]}" = "gaia-threat-model" ]
  [ "${_PFD_REMAINING[2]}" = "--unknown-flag" ]
}

@test "no args yields empty exports" {
  source "$PARSER"
  _parse_force_design
  [ -z "$FORCE_DESIGN" ]
  [ -z "$FORCE_DESIGN_REASON" ]
  [ -z "$FORCE_DESIGN_ENTRY_POINT" ]
  [ -z "$FORCE_DESIGN_SPRINT_ID" ]
  [ "${#_PFD_REMAINING[@]}" -eq 0 ]
}

@test "--reason without a value exits 2" {
  source "$PARSER"
  run _parse_force_design --force-design --reason
  [ "$status" -eq 2 ]
}

@test "--entry-point without a value exits 2" {
  source "$PARSER"
  run _parse_force_design --entry-point
  [ "$status" -eq 2 ]
}

@test "--sprint-id without a value exits 2" {
  source "$PARSER"
  run _parse_force_design --sprint-id
  [ "$status" -eq 2 ]
}

@test "double-source guard prevents re-initialization" {
  source "$PARSER"
  _parse_force_design --force-design --reason "first"
  [ "$FORCE_DESIGN" = "1" ]

  # Source again — the guard should prevent re-execution of the body
  source "$PARSER"
  # The function should still be available
  _parse_force_design --reason "second"
  [ "$FORCE_DESIGN_REASON" = "second" ]
}
