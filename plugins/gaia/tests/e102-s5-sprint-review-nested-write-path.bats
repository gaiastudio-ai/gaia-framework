#!/usr/bin/env bats
# e102-s5-sprint-review-nested-write-path.bats
# Story: E102-S5 — gaia-sprint-review writes to implementation-artifacts/sprint-review/

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$PLUGIN/skills/gaia-sprint-review/SKILL.md"
  SCRIPTS_DIR="$PLUGIN/skills/gaia-sprint-review/scripts"
}

teardown() { common_teardown; }

@test "SKILL.md references nested sprint-review path" {
  [ -f "$SKILL" ]
  grep -qF "implementation-artifacts/sprint-review/sprint-review-" "$SKILL"
}

@test "no script writes to legacy flat sprint-review path" {
  [ -d "$SCRIPTS_DIR" ]
  ! grep -rnE 'implementation-artifacts/sprint-review-\$\{?SPRINT_ID' "$SCRIPTS_DIR" 2>/dev/null
}

@test "SKILL.md includes mkdir -p guidance for nested directory" {
  [ -f "$SKILL" ]
  grep -qF "mkdir -p" "$SKILL"
}
