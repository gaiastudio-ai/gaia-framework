#!/usr/bin/env bats
# type-target-resolver.bats — gaia-meeting eleven-type type → target_command resolver (E76-S3)
#
# AC3 / FR-MTG-20 / ADR-086 / TC-MTG-AI-2

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/lib/type-target-resolver.sh"
}

@test "Pre-flight: type-target-resolver.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "a feature item resolves to the add-feature command" {
  run "$HELPER" feature
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-add-feature" ]
}

@test "a prd-edit item resolves to the edit-prd command" {
  run "$HELPER" prd-edit
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-edit-prd" ]
}

@test "a ux-edit item resolves to the edit-ux command" {
  run "$HELPER" ux-edit
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-edit-ux" ]
}

@test "an arch-edit item resolves to the edit-arch command" {
  run "$HELPER" arch-edit
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-edit-arch" ]
}

@test "a test-edit item resolves to the edit-test-plan command" {
  run "$HELPER" test-edit
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-edit-test-plan" ]
}

@test "a new-story item resolves to the create-story command" {
  run "$HELPER" new-story
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-create-story" ]
}

@test "a sprint-correction item resolves to the correct-course command" {
  run "$HELPER" sprint-correction
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-correct-course" ]
}

@test "a sprint-plan item resolves to the sprint-plan command" {
  run "$HELPER" sprint-plan
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-sprint-plan" ]
}

@test "a brainstorm-followup item resolves to the brainstorm command" {
  run "$HELPER" brainstorm-followup
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-brainstorm" ]
}

@test "a decision-record draft resolves to no target and is handled manually" {
  run "$HELPER" adr-draft
  [ "$status" -eq 0 ]
  [ "$output" = "no target — manual" ]
}

@test "a discussion-only item resolves to no target" {
  run "$HELPER" discussion-only
  [ "$status" -eq 0 ]
  [ "$output" = "no target — discussion-only" ]
}

@test "an unknown type is rejected with a non-zero exit rather than defaulting silently" {
  run "$HELPER" some-unknown-type
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "an empty type is rejected" {
  run "$HELPER" ""
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
