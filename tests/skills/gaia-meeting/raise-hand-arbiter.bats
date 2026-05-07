#!/usr/bin/env bats
# raise-hand-arbiter.bats — gaia-meeting raise-hand insertion + one-per-cycle (E76-S2)
#
# Covers AC8, AC9 / TC-MTG-TURN-2, TC-MTG-TURN-3.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/raise-hand-arbiter.sh"
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}

@test "Pre-flight: raise-hand-arbiter.sh exists and is executable" {
  [ -x "$HELPER" ]
}

# AC8 / TC-MTG-TURN-2: detect raise-hand marker
@test "AC8: --detect emits the named target when input contains raise-hand marker" {
  run "$HELPER" --detect "I would like more context. [raise-hand → respond to Christy]"
  [ "$status" -eq 0 ]
  [ "$output" = "Christy" ]
}

@test "AC8: --detect supports ASCII '->' arrow form" {
  run "$HELPER" --detect "[raise-hand -> respond to Theo]"
  [ "$status" -eq 0 ]
  [ "$output" = "Theo" ]
}

@test "AC8: --detect on input with NO raise-hand exits non-zero" {
  run "$HELPER" --detect "A normal turn body without any flag."
  [ "$status" -ne 0 ]
}

# AC8 / TC-MTG-TURN-2: insertion makes named agent next, then resumes round-robin
@test "AC8: --plan-insertion produces inserted-then-resumed sequence" {
  # Round [A,B,C,D]; A's turn ends with raise-hand to C; expected next:
  #   C, B, C, D  (C inserted, then resume from B as the otherwise-next slot)
  run "$HELPER" --plan-insertion --invitees "A,B,C,D" --requesting A --target C --cycle 1
  [ "$status" -eq 0 ]
  expected="C
B
C
D"
  [ "$output" = "$expected" ]
}

@test "AC8: insertion of an invitee NOT in the round is rejected" {
  run "$HELPER" --plan-insertion --invitees "A,B,C,D" --requesting A --target Z --cycle 1
  [ "$status" -ne 0 ]
}

# AC9 / TC-MTG-TURN-3: one raise-hand per cycle
@test "AC9 / TC-MTG-TURN-3: --record-raise-hand returns 'honored' on first request in cycle" {
  state="$TMP_DIR/state.env"
  RAISE_HAND_STATE="$state" run "$HELPER" --record-raise-hand --cycle 1 --requesting A --target C
  [ "$status" -eq 0 ]
  [ "$output" = "honored" ]
}

@test "AC9 / TC-MTG-TURN-3: second raise-hand within same cycle is 'deferred-to-next-cycle'" {
  state="$TMP_DIR/state.env"
  RAISE_HAND_STATE="$state" run "$HELPER" --record-raise-hand --cycle 1 --requesting A --target C
  [ "$status" -eq 0 ]
  [ "$output" = "honored" ]
  RAISE_HAND_STATE="$state" run "$HELPER" --record-raise-hand --cycle 1 --requesting B --target D
  [ "$status" -eq 0 ]
  [ "$output" = "deferred-to-next-cycle" ]
}

@test "AC9: cycle 2 honors a fresh raise-hand even after cycle 1 used its slot" {
  state="$TMP_DIR/state.env"
  RAISE_HAND_STATE="$state" "$HELPER" --record-raise-hand --cycle 1 --requesting A --target C >/dev/null
  RAISE_HAND_STATE="$state" run "$HELPER" --record-raise-hand --cycle 2 --requesting B --target D
  [ "$status" -eq 0 ]
  [ "$output" = "honored" ]
}

@test "AC9: --pending-deferred lists deferred raise-hands for the next cycle" {
  state="$TMP_DIR/state.env"
  RAISE_HAND_STATE="$state" "$HELPER" --record-raise-hand --cycle 1 --requesting A --target C >/dev/null
  RAISE_HAND_STATE="$state" "$HELPER" --record-raise-hand --cycle 1 --requesting B --target D >/dev/null
  RAISE_HAND_STATE="$state" run "$HELPER" --pending-deferred --cycle 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"B->D"* ]] || [[ "$output" == *"B -> D"* ]] || [[ "$output" == *"B,D"* ]]
}

# AC8: log line format
@test "AC8: --log-line emits arbitration record with requesting / named / cycle" {
  run "$HELPER" --log-line --cycle 3 --requesting A --target C --status honored
  [ "$status" -eq 0 ]
  [[ "$output" == *"cycle=3"* ]]
  [[ "$output" == *"A"* ]]
  [[ "$output" == *"C"* ]]
  [[ "$output" == *"honored"* ]]
}

@test "AC9: --log-line for deferred annotation includes 'deferred-to-next-cycle'" {
  run "$HELPER" --log-line --cycle 3 --requesting A --target C --status deferred-to-next-cycle
  [ "$status" -eq 0 ]
  [[ "$output" == *"deferred-to-next-cycle"* ]]
}
