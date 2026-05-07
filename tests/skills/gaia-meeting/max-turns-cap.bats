#!/usr/bin/env bats
# max-turns-cap.bats — gaia-meeting max-turns guardrail (E76-S6)
#
# AC4 / FR-MTG-29 / TC-MTG-GUARD-2: default cap = 40, override via --max-turns N.
# (cap+1)th turn rejected before emission with explanation referencing FR-MTG-29.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/max-turns-cap.sh"
}

@test "Pre-flight: max-turns-cap.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC4: default cap is 40 — turn 40 is allowed" {
  run "$HELPER" --check --emitted-turns 40
  [ "$status" -eq 0 ]
}

@test "AC4: default cap is 40 — turn 41 is rejected" {
  run "$HELPER" --check --emitted-turns 41
  [ "$status" -eq 2 ]
  [[ "$output" == *"FR-MTG-29"* ]]
  [[ "$output" == *"40"* ]]
}

@test "AC4: --max-turns 5 override caps at 5 — turn 5 allowed" {
  run "$HELPER" --check --emitted-turns 5 --max-turns 5
  [ "$status" -eq 0 ]
}

@test "AC4: --max-turns 5 override caps at 5 — turn 6 rejected" {
  run "$HELPER" --check --emitted-turns 6 --max-turns 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"FR-MTG-29"* ]]
}

@test "AC4: termination event is logged on cap hit" {
  run "$HELPER" --check --emitted-turns 41
  [ "$status" -eq 2 ]
  [[ "$output" == *"MAX-TURNS-CAP"* ]] || [[ "$output" == *"max-turns"* ]]
}

@test "AC4: rejects --max-turns 0 (malformed)" {
  run "$HELPER" --check --emitted-turns 1 --max-turns 0
  [ "$status" -eq 3 ]
}

@test "AC4: rejects negative --max-turns (malformed)" {
  run "$HELPER" --check --emitted-turns 1 --max-turns -1
  [ "$status" -eq 3 ]
}

@test "AC4: --emitted-turns must be non-negative integer" {
  run "$HELPER" --check --emitted-turns abc
  [ "$status" -eq 3 ]
}
