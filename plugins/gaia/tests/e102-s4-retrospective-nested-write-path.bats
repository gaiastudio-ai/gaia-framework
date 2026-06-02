#!/usr/bin/env bats
# e102-s4-retrospective-nested-write-path.bats
#
# Story: E102-S4 — gaia-retro writes retrospectives to implementation-artifacts/retrospective/
# Origin: AF-2026-05-24-2. Traces to: FR-534, ADR-119, TC-ASG-4.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$PLUGIN/skills/gaia-retro/SKILL.md"
  SCRIPTS_DIR="$PLUGIN/skills/gaia-retro/scripts"
}

teardown() { common_teardown; }

@test "TC-ASG-4-retro-a: SKILL.md references nested retrospective path" {
  [ -f "$SKILL" ]
  grep -qF "implementation-artifacts/retrospective/retrospective-" "$SKILL"
}

@test "TC-ASG-4-retro-b: no script writes to legacy flat retrospective path" {
  [ -d "$SCRIPTS_DIR" ]
  # Match the legacy flat write path; expect zero hits.
  ! grep -rnE 'implementation-artifacts/retrospective-\$\{?sprint_id' "$SCRIPTS_DIR" 2>/dev/null
}

@test "TC-ASG-4-retro-c: SKILL.md includes mkdir -p guidance for nested directory" {
  [ -f "$SKILL" ]
  grep -qF "mkdir -p" "$SKILL"
}

@test "TC-ASG-4-retro-d: documented write target ends with retrospective-{sprint_id}-{date}.md under retrospective/" {
  [ -f "$SKILL" ]
  grep -qE "implementation-artifacts/retrospective/retrospective-\{sprint_id\}" "$SKILL"
}
