#!/usr/bin/env bats
# no-priority-flag-auto-set.bats — E83-S5 regression-guard check
#
# Asserts that the /gaia-add-feature SKILL.md and supporting scripts do NOT
# contain any conditional that auto-sets the priority_flag field with the
# value next-sprint on stories created via cascade. This guards user
# memory rule feedback_priority_flag_never_auto_set.md.
#
# The triage stage classifies (priority); /gaia-sprint-plan sequences
# (priority_flag). Auto-setting at cascade time pre-empts sprint-plan
# authority and produces double-counted claims for the next sprint.
#
# Test cases (AC mapping):
#   AC #1 — regression-guard grep returns zero matches in SKILL.md + scripts/
#   AC #5 — bats file exists and is wired into CI
#
# NOTE on token-splitting: this header intentionally avoids placing the
# field-name and the value on the same line so the very regex this test
# asserts against does NOT match the prose of this file. The string
# literals in the @test bodies use single-quoted shell args that the
# guard regex DOES match — but those instances live under tests/ which
# is intentionally outside the regression-guard scope (SKILL.md and
# scripts/ only). Test Scenario #7 in the story ("Negative — no other
# auto-setter introduced") greps SKILL.md files only across all skills
# and confirms zero matches.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-add-feature"
  export LC_ALL=C
}

# AC #1 — regression-guard grep returns zero matches under the skill tree
# (excluding tests/ — this self-documenting test file references the
# pattern in setup commentary).
@test "no auto-setter under gaia-add-feature SKILL.md" {
  run grep -rE 'priority_flag.*next-sprint' "$SKILL_DIR/SKILL.md"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "no auto-setter under gaia-add-feature scripts/" {
  run grep -rE 'priority_flag.*next-sprint' "$SKILL_DIR/scripts/"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# AC #2 — explicit prose note replaces the deleted conditional
@test "SKILL.md contains the explicit prose note referencing the memory rule" {
  run grep -F "Per user rule \`feedback_priority_flag_never_auto_set.md\`" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# AC #3 — verbatim memory-rule callout block present
@test "SKILL.md contains the verbatim memory-rule quote" {
  run grep -F "Stories produced by /gaia-add-feature MUST have priority_flag: null" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# AC #5 — bats file exists (self-referential — passes by virtue of running)
@test "bats regression test file exists" {
  [ -f "$SKILL_DIR/tests/no-priority-flag-auto-set.bats" ]
}

# AC #5 — CI wiring (static check)
@test "plugin-ci.yml references no-priority-flag-auto-set" {
  CI_FILE="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  [ -f "$CI_FILE" ]
  run grep -F "no-priority-flag-auto-set" "$CI_FILE"
  [ "$status" -eq 0 ]
}
