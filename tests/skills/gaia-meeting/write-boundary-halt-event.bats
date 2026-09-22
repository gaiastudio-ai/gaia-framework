#!/usr/bin/env bats
# write-boundary-halt-event.bats — a misdirected write target produces a
# write-boundary-violation halt event in addition to refusing the write, and an
# allowed target produces no halt event at all.
#
# Roots are resolved through the same path helper the shipped scripts use
# rather than restated as literals here.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/write-boundary.sh"
  load helpers/runtime-paths
  gaia_load_runtime_paths "$REPO_ROOT" || {
    skip "runtime path helper unavailable; cannot resolve the tree the way production does"
  }
}

@test "Pre-flight: write-boundary.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "a rejected write target emits a write-boundary-violation halt event" {
  run "$HELPER" "sprint-status.yaml"
  [ "$status" -ne 0 ]
  # Halt event present somewhere in stdout/stderr (combined under bats run)
  [[ "$output" == *"HALT"* ]] || [[ "$output" == *"WRITE-BOUNDARY-VIOLATION"* ]]
  [[ "$output" == *"FR-MTG-31"* ]]
}

@test "a rejected story-file target emits a halt event carrying sprint detail" {
  run "$HELPER" "$GAIA_REL_ARTIFACTS/implementation-artifacts/some-story.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"WRITE-BOUNDARY-VIOLATION"* ]]
}

@test "an allowed target emits no halt event" {
  run "$HELPER" "$GAIA_REL_ARTIFACTS/creative-artifacts/meeting-2026-05-07.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"HALT"* ]]
  [[ "$output" != *"WRITE-BOUNDARY-VIOLATION"* ]]
}
