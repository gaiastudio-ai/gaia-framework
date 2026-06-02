#!/usr/bin/env bats
# e102-s3-sprint-plan-nested-write-path.bats
#
# Story: E102-S3 — gaia-sprint-plan writes plans to implementation-artifacts/sprint-plan/
# Origin: AF-2026-05-24-2. Traces to: FR-533, ADR-119, TC-ASG-3.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  SKILL="$REPO_ROOT/gaia-public/plugins/gaia/skills/gaia-sprint-plan/SKILL.md"
  SCRIPTS_DIR="$REPO_ROOT/gaia-public/plugins/gaia/skills/gaia-sprint-plan/scripts"
}

teardown() { common_teardown; }

@test "TC-ASG-3a: SKILL.md references nested sprint-plan path" {
  [ -f "$SKILL" ]
  grep -qF "implementation-artifacts/sprint-plan/" "$SKILL"
}

@test "TC-ASG-3b: no script writes to legacy flat sprint-plan path" {
  [ -d "$SCRIPTS_DIR" ]
  # Pattern matches the legacy flat path; should be zero hits.
  ! grep -rnE 'implementation-artifacts/\$\{?sprint_id\}?-plan\.md' "$SCRIPTS_DIR" 2>/dev/null
}

@test "TC-ASG-3c: SKILL.md includes mkdir -p guidance for nested directory" {
  [ -f "$SKILL" ]
  grep -qF "mkdir -p" "$SKILL"
}

@test "TC-ASG-3d: Step 7 write target ends with {sprint_id}-plan.md under sprint-plan/" {
  [ -f "$SKILL" ]
  grep -qE "implementation-artifacts/sprint-plan/.*sprint_id.*-plan\.md" "$SKILL"
}

@test "TC-ASG-3e: Step 11 Val-sidecar artifact_path uses nested form" {
  [ -f "$SKILL" ]
  grep -qF "artifact_path \".gaia/artifacts/implementation-artifacts/sprint-plan/" "$SKILL"
}
