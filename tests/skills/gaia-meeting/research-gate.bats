#!/usr/bin/env bats
# research-gate.bats — gaia-meeting research-phase completeness gate (E76-S6)
#
# AC2 / FR-MTG-28 / TC-MTG-GUARD-1: phase-transition gate from RESEARCH to
# DISCUSS requires one structured prelude per invited agent. Bypasses only on
# --skip-research. On halt, emits a HALT event and refuses phase advancement.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/research-gate.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: research-gate.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "passes when one prelude exists per invitee" {
  : > "$TMP/preludes.txt"
  printf 'theo\nderek\n' > "$TMP/preludes.txt"
  run "$HELPER" --invitees "theo,derek" --preludes-file "$TMP/preludes.txt"
  [ "$status" -eq 0 ]
}

@test "HALTs when one or more preludes are missing" {
  printf 'theo\n' > "$TMP/preludes.txt"
  run "$HELPER" --invitees "theo,derek" --preludes-file "$TMP/preludes.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"HALT"* ]]
  [[ "$output" == *"condition=RESEARCH-MISSING"* ]]
  [[ "$output" == *"fr=FR-MTG-28"* ]]
}

@test "HALTs when the preludes file is missing entirely" {
  run "$HELPER" --invitees "theo" --preludes-file "$TMP/nonexistent.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"HALT"* ]]
}

@test "--skip-research bypasses the gate" {
  run "$HELPER" --invitees "theo,derek" --preludes-file "$TMP/nonexistent.txt" --skip-research
  [ "$status" -eq 0 ]
}

@test "an empty invitees list is malformed args (exit 3)" {
  run "$HELPER" --invitees "" --preludes-file "$TMP/preludes.txt"
  [ "$status" -eq 3 ]
}
