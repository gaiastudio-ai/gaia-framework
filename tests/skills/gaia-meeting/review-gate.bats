#!/usr/bin/env bats
# review-gate.bats — gaia-meeting REVIEW-phase disposition router (E76-S3)
#
# AC1 / AC10 / FR-MTG-12 / FR-MTG-31

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GATE="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/review-gate.sh"
  TMPDIR_T="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "Pre-flight: review-gate.sh exists and is executable" {
  [ -x "$GATE" ]
}

@test "classify reports ACCEPT for a draft dispositioned accept" {
  draft="$TMPDIR_T/d.md"
  echo "draft body" > "$draft"
  run "$GATE" --classify --draft "$draft" --disposition accept
  [ "$status" -eq 0 ]
  [ "$output" = "ACCEPT" ]
}

@test "classify reports DROP for a draft dispositioned drop" {
  draft="$TMPDIR_T/d.md"
  echo "draft body" > "$draft"
  run "$GATE" --classify --draft "$draft" --disposition drop
  [ "$status" -eq 0 ]
  [ "$output" = "DROP" ]
}

@test "classify reports EDIT for a draft dispositioned edit" {
  draft="$TMPDIR_T/d.md"
  echo "draft body" > "$draft"
  run "$GATE" --classify --draft "$draft" --disposition edit
  [ "$status" -eq 0 ]
  [ "$output" = "EDIT" ]
}

@test "should-write succeeds on accept so the write proceeds" {
  run "$GATE" --should-write --disposition accept
  [ "$status" -eq 0 ]
}

@test "should-write returns 1 on drop so the write is suppressed" {
  run "$GATE" --should-write --disposition drop
  [ "$status" -eq 1 ]
}

@test "should-write succeeds on edit so the draft is re-rendered then written" {
  run "$GATE" --should-write --disposition edit
  [ "$status" -eq 0 ]
}

@test "an invalid disposition is rejected" {
  run "$GATE" --should-write --disposition foo
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [ "$status" -ne 127 ]
}
