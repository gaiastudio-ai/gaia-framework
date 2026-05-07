#!/usr/bin/env bats
# single-mode-invariant.bats — gaia-meeting single-mode-only enforcement (E76-S5)
#
# T2 / AC9 / AC10 / FR-MTG-16
#
# Verifies resolve-mode.sh extends its KNOWN_MODES allowlist to include the
# eight new modes added in this story while preserving E76-S1's mode-stacking
# rejection.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/resolve-mode.sh"
}

@test "AC10: --mode explore is accepted" {
  run "$HELPER" --mode explore
  [ "$status" -eq 0 ]
  [ "$output" = "explore" ]
}

@test "AC10: --mode align is accepted" {
  run "$HELPER" --mode align
  [ "$status" -eq 0 ]
  [ "$output" = "align" ]
}

@test "AC10: --mode red-team is accepted" {
  run "$HELPER" --mode red-team
  [ "$status" -eq 0 ]
  [ "$output" = "red-team" ]
}

@test "AC10: --mode ac is accepted" {
  run "$HELPER" --mode ac
  [ "$status" -eq 0 ]
  [ "$output" = "ac" ]
}

@test "AC10: --mode brainstorm is accepted" {
  run "$HELPER" --mode brainstorm
  [ "$status" -eq 0 ]
  [ "$output" = "brainstorm" ]
}

@test "AC6: --mode design is accepted (resolves to canonical name design)" {
  run "$HELPER" --mode design
  [ "$status" -eq 0 ]
  [ "$output" = "design" ]
}

@test "AC6: --mode ux is accepted and canonicalises to design" {
  run "$HELPER" --mode ux
  [ "$status" -eq 0 ]
  [ "$output" = "design" ]
}

@test "AC10: --mode architecture is accepted" {
  run "$HELPER" --mode architecture
  [ "$status" -eq 0 ]
  [ "$output" = "architecture" ]
}

@test "AC10: --mode sprint is accepted" {
  run "$HELPER" --mode sprint
  [ "$status" -eq 0 ]
  [ "$output" = "sprint" ]
}

@test "AC9: two --mode flags rejected with non-zero exit and lists both values" {
  run "$HELPER" --mode architecture --mode red-team
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
  echo "$output" | grep -qiE "single|stack|one"
  # AC9 requires the message to list BOTH supplied values
  echo "$output" | grep -qE "architecture"
  echo "$output" | grep -qE "red-team"
}

@test "FR-MTG-16: stacking still rejected with two of the new modes" {
  run "$HELPER" --mode brainstorm --mode sprint
  [ "$status" -ne 0 ]
}

@test "AC9 message references FR-MTG-16 v1 constraint" {
  run "$HELPER" --mode architecture --mode red-team
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE "FR-MTG-16"
}

@test "Unknown mode still rejected" {
  run "$HELPER" --mode notamode
  [ "$status" -ne 0 ]
}
