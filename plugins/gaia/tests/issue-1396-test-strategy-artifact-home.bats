#!/usr/bin/env bash
# issue-1396-test-strategy-artifact-home.bats
#
# gaia-test-strategy/SKILL.md contradicted itself: one rule said "Output ALL
# artifacts to .gaia/artifacts/test-artifacts/" while the mode descriptions
# declared planning-artifacts/ as the canonical home for test-strategy.md +
# test-plan.md. This guards the reconciliation: the doc artifacts land in
# planning-artifacts/, and there is no blanket "ALL artifacts → test-artifacts"
# rule.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_MD="$PLUGIN_ROOT/skills/gaia-test-strategy/SKILL.md"
}
teardown() { common_teardown; }

@test "issue-1396: SKILL.md exists" {
  [ -f "$SKILL_MD" ]
}

@test "issue-1396: no blanket 'Output ALL artifacts to .../test-artifacts/' rule" {
  ! grep -qE 'Output ALL artifacts to .*test-artifacts' "$SKILL_MD"
}

@test "issue-1396: the doc artifacts are routed to planning-artifacts/" {
  # The reconciled rule names the two doc artifacts + the planning-artifacts home.
  grep -qE 'test-strategy.md.*test-plan.md|test-plan.md.*test-strategy.md' "$SKILL_MD"
  grep -qF 'planning-artifacts/' "$SKILL_MD"
}

@test "issue-1396: scaffold artifacts are explicitly NOT routed into the artifact buckets" {
  grep -qiE 'scaffold artifacts.*(service path|tests/)' "$SKILL_MD"
}
