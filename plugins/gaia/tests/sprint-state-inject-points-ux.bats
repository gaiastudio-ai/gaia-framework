#!/usr/bin/env bats
# sprint-state-inject-points-ux.bats — E57-S15 / AI-2026-05-15-3.
#
# Tests the UX polish around the unimplemented `--points` flag on
# `sprint-state.sh inject`. The script accumulates total_points from the
# injected story's frontmatter `points:` field; no CLI flag is accepted.
# Pre-fix the rejection was the bare "unknown flag: --points" message;
# post-fix it's a redirect explaining the actual contract.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SPRINT_STATE="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"

setup() { common_setup; }
teardown() { common_teardown; }

@test "TC-SSI-1: sprint-state.sh inject --points 5 -> helpful error message, exit non-zero" {
  run --separate-stderr "$SPRINT_STATE" inject --points 5
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"--points is not a valid flag for inject"* ]]
  [[ "$stderr" == *"total_points is accumulated from the injected story's frontmatter points:"* ]]
  # Generic "unknown flag" rejection must NOT be the message — that
  # would mean the AC2 helpful-error branch did not fire.
  [[ "$stderr" != *"unknown flag: --points"* ]]
}

@test "TC-SSI-1b: --points=5 (long-form value) hits the same helpful error" {
  run --separate-stderr "$SPRINT_STATE" inject --points=5
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"--points is not a valid flag for inject"* ]]
}

@test "TC-SSI-3: --help output documents total_points accumulation behavior" {
  run "$SPRINT_STATE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"total_points: accumulated from the injected story's"* ]]
  [[ "$output" == *"frontmatter"* ]]
  [[ "$output" == *"points:"* ]]
  # AC4: the seed rule itself must be documented (was a cross-reference to the
  # saved-memory rule; the durable anchor is the behavioral phrase).
  [[ "$output" == *"Boundary-write seed rule"* ]]
}

@test "TC-SSI-4: other unknown flags still get the generic 'unknown flag' rejection" {
  run --separate-stderr "$SPRINT_STATE" inject --bogus-flag x
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unknown flag: --bogus-flag"* ]]
}
