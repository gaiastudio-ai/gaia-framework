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

@test "--mode explore is accepted" {
  run "$HELPER" --mode explore
  [ "$status" -eq 0 ]
  [ "$output" = "explore" ]
}

@test "--mode align is accepted" {
  run "$HELPER" --mode align
  [ "$status" -eq 0 ]
  [ "$output" = "align" ]
}

@test "--mode red-team is accepted" {
  run "$HELPER" --mode red-team
  [ "$status" -eq 0 ]
  [ "$output" = "red-team" ]
}

@test "--mode ac is accepted" {
  run "$HELPER" --mode ac
  [ "$status" -eq 0 ]
  [ "$output" = "ac" ]
}

@test "--mode brainstorm is accepted" {
  run "$HELPER" --mode brainstorm
  [ "$status" -eq 0 ]
  [ "$output" = "brainstorm" ]
}

@test "--mode design is accepted and resolves to the canonical name design" {
  run "$HELPER" --mode design
  [ "$status" -eq 0 ]
  [ "$output" = "design" ]
}

@test "--mode ux is accepted and canonicalises to design" {
  run "$HELPER" --mode ux
  [ "$status" -eq 0 ]
  [ "$output" = "design" ]
}

@test "--mode architecture is accepted" {
  run "$HELPER" --mode architecture
  [ "$status" -eq 0 ]
  [ "$output" = "architecture" ]
}

@test "--mode sprint is accepted" {
  run "$HELPER" --mode sprint
  [ "$status" -eq 0 ]
  [ "$output" = "sprint" ]
}

@test "two --mode flags are rejected with a non-zero exit and both values are listed" {
  run "$HELPER" --mode architecture --mode red-team
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
  echo "$output" | grep -qiE "single|stack|one"
  # AC9 requires the message to list BOTH supplied values
  echo "$output" | grep -qE "architecture"
  echo "$output" | grep -qE "red-team"
}

@test "stacking two of the newer modes is still rejected" {
  run "$HELPER" --mode brainstorm --mode sprint
  [ "$status" -ne 0 ]
}

@test "the rejection message cites the single-mode constraint" {
  run "$HELPER" --mode architecture --mode red-team
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE "FR-MTG-16"
}

@test "Unknown mode still rejected" {
  run "$HELPER" --mode notamode
  [ "$status" -ne 0 ]
}
