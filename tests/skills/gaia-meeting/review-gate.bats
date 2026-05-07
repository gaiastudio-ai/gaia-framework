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

@test "AC1: classify a draft with disposition accept" {
  draft="$TMPDIR_T/d.md"
  echo "draft body" > "$draft"
  run "$GATE" --classify --draft "$draft" --disposition accept
  [ "$status" -eq 0 ]
  [ "$output" = "ACCEPT" ]
}

@test "AC1: classify a draft with disposition drop" {
  draft="$TMPDIR_T/d.md"
  echo "draft body" > "$draft"
  run "$GATE" --classify --draft "$draft" --disposition drop
  [ "$status" -eq 0 ]
  [ "$output" = "DROP" ]
}

@test "AC1: classify a draft with disposition edit" {
  draft="$TMPDIR_T/d.md"
  echo "draft body" > "$draft"
  run "$GATE" --classify --draft "$draft" --disposition edit
  [ "$status" -eq 0 ]
  [ "$output" = "EDIT" ]
}

@test "AC1: should-write returns 0 when disposition is accept (write proceeds)" {
  run "$GATE" --should-write --disposition accept
  [ "$status" -eq 0 ]
}

@test "AC1: should-write returns 1 when disposition is drop (write suppressed)" {
  run "$GATE" --should-write --disposition drop
  [ "$status" -eq 1 ]
}

@test "AC1: should-write returns 0 when disposition is edit (re-render then write)" {
  run "$GATE" --should-write --disposition edit
  [ "$status" -eq 0 ]
}

@test "AC1: invalid disposition is rejected" {
  run "$GATE" --should-write --disposition foo
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [ "$status" -ne 127 ]
}
