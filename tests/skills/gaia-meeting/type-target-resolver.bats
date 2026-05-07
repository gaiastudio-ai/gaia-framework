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

@test "AC3: feature -> /gaia-add-feature" {
  run "$HELPER" feature
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-add-feature" ]
}

@test "AC3: prd-edit -> /gaia-edit-prd" {
  run "$HELPER" prd-edit
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-edit-prd" ]
}

@test "AC3: ux-edit -> /gaia-edit-ux" {
  run "$HELPER" ux-edit
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-edit-ux" ]
}

@test "AC3: arch-edit -> /gaia-edit-arch" {
  run "$HELPER" arch-edit
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-edit-arch" ]
}

@test "AC3: test-edit -> /gaia-edit-test-plan" {
  run "$HELPER" test-edit
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-edit-test-plan" ]
}

@test "AC3: new-story -> /gaia-create-story" {
  run "$HELPER" new-story
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-create-story" ]
}

@test "AC3: sprint-correction -> /gaia-correct-course" {
  run "$HELPER" sprint-correction
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-correct-course" ]
}

@test "AC3: sprint-plan -> /gaia-sprint-plan" {
  run "$HELPER" sprint-plan
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-sprint-plan" ]
}

@test "AC3: brainstorm-followup -> /gaia-brainstorm" {
  run "$HELPER" brainstorm-followup
  [ "$status" -eq 0 ]
  [ "$output" = "/gaia-brainstorm" ]
}

@test "AC3: adr-draft -> 'no target — manual'" {
  run "$HELPER" adr-draft
  [ "$status" -eq 0 ]
  [ "$output" = "no target — manual" ]
}

@test "AC3: discussion-only -> 'no target — discussion-only'" {
  run "$HELPER" discussion-only
  [ "$status" -eq 0 ]
  [ "$output" = "no target — discussion-only" ]
}

@test "AC3: unknown type rejected with non-zero exit (no silent default)" {
  run "$HELPER" some-unknown-type
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC3: empty type rejected" {
  run "$HELPER" ""
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
