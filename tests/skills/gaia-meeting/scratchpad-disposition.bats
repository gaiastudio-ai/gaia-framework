#!/usr/bin/env bats
# scratchpad-disposition.bats — gaia-meeting close-time disposition validator (E76-S4)
#
# AC4 / AC13 / FR-MTG-12. Exercises TC-MTG-SP-2.
#
# Validates that the disposition value is one of three canonical labels
# (Extract / Keep / Drop), case-insensitive, and rejects any other value.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/scratchpad-disposition.sh"
}

@test "Pre-flight: scratchpad-disposition.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC4 (TC-MTG-SP-2): Extract is accepted" {
  run "$HELPER" --check Extract
  [ "$status" -eq 0 ]
  [ "$output" = "extract" ]
}

@test "AC4: Keep is accepted" {
  run "$HELPER" --check Keep
  [ "$status" -eq 0 ]
  [ "$output" = "keep" ]
}

@test "AC4: Drop is accepted" {
  run "$HELPER" --check Drop
  [ "$status" -eq 0 ]
  [ "$output" = "drop" ]
}

@test "AC4: case-insensitive — extract / EXTRACT / Extract all map to extract" {
  run "$HELPER" --check extract; [ "$output" = "extract" ]
  run "$HELPER" --check EXTRACT; [ "$output" = "extract" ]
  run "$HELPER" --check Extract; [ "$output" = "extract" ]
}

@test "AC4: an unknown disposition is REJECTED with exit 2" {
  run "$HELPER" --check Maybe
  [ "$status" -eq 2 ]
}

@test "AC4: an empty disposition is REJECTED" {
  run "$HELPER" --check ""
  [ "$status" -eq 2 ]
}

@test "AC4: --prompt prints the canonical three-option prompt" {
  run "$HELPER" --prompt
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Extract"
  echo "$output" | grep -q "Keep in notes only"
  echo "$output" | grep -q "Drop"
}
