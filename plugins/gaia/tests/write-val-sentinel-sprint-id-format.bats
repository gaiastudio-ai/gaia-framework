#!/usr/bin/env bats
# write-val-sentinel-sprint-id-format.bats — E93 manual-test ISSUE-5 regression coverage.
#
# Verifies that write-val-sentinel.sh's sprint_id format regex accepts
# descriptive sprint IDs (e.g., sprint-test-1, sprint-fixture-a) while
# still rejecting path-traversal sequences per the T-37 mitigation.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../skills/gaia-sprint-review/scripts/write-val-sentinel.sh"
  TMPDIR_TEST="$(mktemp -d)"
  export CHECKPOINT_PATH="$TMPDIR_TEST/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  PAYLOAD='{"status":"PASS","summary":"test","findings":[],"agent":"val"}'
}

teardown() {
  rm -rf "$TMPDIR_TEST"
  unset CHECKPOINT_PATH
}

@test "numeric sprint ID (production form) accepted" {
  run bash -c "echo '$PAYLOAD' | bash '$SCRIPT' --sprint-id sprint-47"
  [ "$status" -eq 0 ]
}

@test "descriptive sprint ID with hyphens accepted (fixture form)" {
  run bash -c "echo '$PAYLOAD' | bash '$SCRIPT' --sprint-id sprint-test-1"
  [ "$status" -eq 0 ]
}

@test "descriptive sprint ID with underscores accepted" {
  run bash -c "echo '$PAYLOAD' | bash '$SCRIPT' --sprint-id sprint-fixture_a"
  [ "$status" -eq 0 ]
}

@test "path-traversal sprint ID REJECTED (T-37 mitigation preserved)" {
  run bash -c "echo '$PAYLOAD' | bash '$SCRIPT' --sprint-id '../../../etc/passwd'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "invalid sprint_id format"
}

@test "sprint-id with shell metachar REJECTED" {
  run bash -c "echo '$PAYLOAD' | bash '$SCRIPT' --sprint-id 'sprint-test;rm -rf'"
  [ "$status" -ne 0 ]
}

@test "sprint-id with space REJECTED" {
  run bash -c "echo '$PAYLOAD' | bash '$SCRIPT' --sprint-id 'sprint-test 1'"
  [ "$status" -ne 0 ]
}

@test "empty sprint-id slug REJECTED" {
  run bash -c "echo '$PAYLOAD' | bash '$SCRIPT' --sprint-id 'sprint-'"
  [ "$status" -ne 0 ]
}
