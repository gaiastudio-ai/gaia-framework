#!/usr/bin/env bats
# meeting-val-bridge-anti-pattern.bats — E90-S2 anti-pattern check.
#
# Mirrors the E87-S6 anti-pattern bats for /gaia-meeting SKILL.md:
# `context: fork` must NOT appear in gaia-meeting/SKILL.md after the
# main-turn Agent dispatch migration (ADR-104). If it reappears, CI
# fails so reviewers catch the regression.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_MD="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-meeting" && pwd)/SKILL.md"
  export SKILL_MD
}

teardown() {
  common_teardown
}

@test "gaia-meeting/SKILL.md contains no 'context: fork' strings" {
  [ -f "$SKILL_MD" ]
  local count
  count="$(grep -c 'context: fork' "$SKILL_MD" || true)"
  [ "${count:-0}" -eq 0 ]
}

@test "anti-pattern bats fails CI when 'context: fork' is reintroduced (synthetic)" {
  local synthetic="$TEST_TMP/synthetic-skill.md"
  printf 'Some prose about context: fork is forbidden after E90-S2.\n' > "$synthetic"
  local count
  count="$(grep -c 'context: fork' "$synthetic")"
  [ "$count" -ge 1 ]
}
