#!/usr/bin/env bats
# turn-order.bats — gaia-meeting round-robin turn arbitration (E76-S1)
#
# AC5 / TC-MTG-TURN-1: invitee order P1, P2, P3 -> turns P1, P2, P3, P1, P2, P3, ...

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/turn-order.sh"
}

@test "Pre-flight: turn-order.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "round-robin turn order matches the invite order over six turns" {
  run "$HELPER" --invitees "P1,P2,P3" --turns 6
  [ "$status" -eq 0 ]
  expected="P1
P2
P3
P1
P2
P3"
  [ "$output" = "$expected" ]
}

@test "a single invitee speaks on every turn" {
  run "$HELPER" --invitees "P1" --turns 3
  [ "$status" -eq 0 ]
  expected="P1
P1
P1"
  [ "$output" = "$expected" ]
}

@test "a four-invitee round of eight turns wraps cleanly" {
  run "$HELPER" --invitees "A,B,C,D" --turns 8
  [ "$status" -eq 0 ]
  expected="A
B
C
D
A
B
C
D"
  [ "$output" = "$expected" ]
}

@test "an empty invitee list is rejected" {
  [ -x "$HELPER" ]
  run "$HELPER" --invitees "" --turns 3
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
