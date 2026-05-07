#!/usr/bin/env bats
# write-boundary-halt-event.bats — gaia-meeting write boundary halt-event (E76-S6)
#
# AC8 + AC9 / FR-MTG-31 / FR-MTG-28: a misdirected write target produces a
# WRITE-BOUNDARY-VIOLATION halt event in addition to refusing the write.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/write-boundary.sh"
}

@test "Pre-flight: write-boundary.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC8 + AC9: rejected write target emits a WRITE-BOUNDARY-VIOLATION halt event" {
  run "$HELPER" "sprint-status.yaml"
  [ "$status" -ne 0 ]
  # Halt event present somewhere in stdout/stderr (combined under bats run)
  [[ "$output" == *"HALT"* ]] || [[ "$output" == *"WRITE-BOUNDARY-VIOLATION"* ]]
  [[ "$output" == *"FR-MTG-31"* ]]
}

@test "AC8 + AC9: rejected story-file target emits halt event with sprint detail" {
  run "$HELPER" "docs/implementation-artifacts/E1-S1-foo.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"WRITE-BOUNDARY-VIOLATION"* ]]
}

@test "AC8 + AC9: allowed targets do NOT emit halt events" {
  run "$HELPER" "docs/creative-artifacts/meeting-2026-05-07.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"HALT"* ]]
  [[ "$output" != *"WRITE-BOUNDARY-VIOLATION"* ]]
}
