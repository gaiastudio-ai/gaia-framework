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

@test "extract is accepted as a disposition" {
  run "$HELPER" --check Extract
  [ "$status" -eq 0 ]
  [ "$output" = "extract" ]
}

@test "keep is accepted as a disposition" {
  run "$HELPER" --check Keep
  [ "$status" -eq 0 ]
  [ "$output" = "keep" ]
}

@test "drop is accepted as a disposition" {
  run "$HELPER" --check Drop
  [ "$status" -eq 0 ]
  [ "$output" = "drop" ]
}

@test "disposition matching is case-insensitive" {
  run "$HELPER" --check extract; [ "$output" = "extract" ]
  run "$HELPER" --check EXTRACT; [ "$output" = "extract" ]
  run "$HELPER" --check Extract; [ "$output" = "extract" ]
}

@test "an unknown disposition is rejected with exit 2" {
  run "$HELPER" --check Maybe
  [ "$status" -eq 2 ]
}

@test "an empty disposition is rejected" {
  run "$HELPER" --check ""
  [ "$status" -eq 2 ]
}

@test "--prompt prints the canonical three-option prompt" {
  run "$HELPER" --prompt
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Extract"
  echo "$output" | grep -q "Keep in notes only"
  echo "$output" | grep -q "Drop"
}
