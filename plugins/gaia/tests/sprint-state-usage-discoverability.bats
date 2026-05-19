#!/usr/bin/env bats
# sprint-state-usage-discoverability.bats — E93 manual-test ISSUE-1 regression coverage.
#
# Verifies that sprint-state.sh's --help output lists the E93-S1
# subcommands (set-goals, get-goals, update-goals, set-review-justification,
# and the sprint-level transition form `transition --sprint <id> --to <state>`).

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/sprint-state.sh"
}

@test "usage mentions set-goals subcommand" {
  bash "$SCRIPT" --help 2>&1 | grep -q "set-goals"
}

@test "usage mentions get-goals subcommand" {
  bash "$SCRIPT" --help 2>&1 | grep -q "get-goals"
}

@test "usage mentions update-goals subcommand" {
  bash "$SCRIPT" --help 2>&1 | grep -q "update-goals"
}

@test "usage mentions set-review-justification subcommand" {
  bash "$SCRIPT" --help 2>&1 | grep -q "set-review-justification"
}

@test "usage mentions sprint-level transition form (transition --sprint)" {
  bash "$SCRIPT" --help 2>&1 | grep -qE "transition[[:space:]]+--sprint"
}
