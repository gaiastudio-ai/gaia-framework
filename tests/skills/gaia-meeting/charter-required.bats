#!/usr/bin/env bats
# charter-required.bats — gaia-meeting charter gate (E76-S1)
#
# AC1 / TC-MTG-CHARTER-1: missing charter -> BLOCKED, no writes
# AC2 / TC-MTG-CHARTER-2: inline --charter accepted, charter recorded

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/charter-gate.sh"
  TMP="$(mktemp -d)"
  export MEETING_STATE_FILE="$TMP/state.env"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: charter-gate.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC1 / TC-MTG-CHARTER-1: missing --charter exits BLOCKED with actionable error" {
  [ -x "$HELPER" ]
  run "$HELPER"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"charter"* ]]
  [[ "$output" == *"--charter"* ]]
}

@test "AC1 / TC-MTG-CHARTER-1: missing --charter writes nothing to state file" {
  [ -x "$HELPER" ]
  run "$HELPER"
  [ ! -f "$MEETING_STATE_FILE" ]
}

@test "AC2 / TC-MTG-CHARTER-2: --charter inline records charter in state" {
  run "$HELPER" --charter "Decide whether to adopt X for Y."
  [ "$status" -eq 0 ]
  [ -f "$MEETING_STATE_FILE" ]
  grep -q "CHARTER=" "$MEETING_STATE_FILE"
  grep -q "Decide whether to adopt X for Y." "$MEETING_STATE_FILE"
}

@test "AC2: empty --charter \"\" treated as missing -> BLOCKED" {
  [ -x "$HELPER" ]
  run "$HELPER" --charter ""
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
  [[ "$output" == *"BLOCKED"* ]]
}
