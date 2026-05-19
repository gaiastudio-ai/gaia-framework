#!/usr/bin/env bats
# sprint-state-yaml-quote-stripping.bats — E93 manual-test ISSUE-2 regression coverage.
#
# Verifies that sprint-state.sh's _yaml_sprint_status() parser strips
# surrounding double/single quotes from the YAML `status:` value before the
# sprint-level transition case-match. Quoted YAML values like
# `status: "active"` previously returned the literal `"active"` (with
# quotes) and silently failed the ADR-108 D1 case-match.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/sprint-state.sh"
  TMPDIR_TEST="$(mktemp -d)"
  YAML="$TMPDIR_TEST/sprint-status.yaml"
  export SPRINT_STATUS_YAML="$YAML"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
  unset SPRINT_STATUS_YAML
}

@test "quoted YAML status (double quotes) parses correctly for sprint-level transitions" {
  cat >"$YAML" <<EOF
sprint_id: sprint-99
status: "active"
duration: "1 week"
velocity_capacity: 20
total_points: 0
started: "2026-05-19"
end_date: "2026-05-26"
stories: []
EOF
  # active→review is gated on all-stories-done; empty stories[] should pass that gate.
  run bash "$SCRIPT" transition --sprint sprint-99 --to review
  [ "$status" -eq 0 ]
  grep -q '^status: review' "$YAML"
}

@test "quoted YAML status (single quotes) parses correctly" {
  cat >"$YAML" <<EOF
sprint_id: sprint-99
status: 'active'
stories: []
EOF
  run bash "$SCRIPT" transition --sprint sprint-99 --to review
  [ "$status" -eq 0 ]
}

@test "unquoted YAML status (legacy form) still works" {
  cat >"$YAML" <<EOF
sprint_id: sprint-99
status: active
stories: []
EOF
  run bash "$SCRIPT" transition --sprint sprint-99 --to review
  [ "$status" -eq 0 ]
}
