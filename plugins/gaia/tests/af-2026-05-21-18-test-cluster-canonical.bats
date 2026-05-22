#!/usr/bin/env bats
# af-2026-05-21-18-test-cluster-canonical.bats
#
# Regression coverage for AF-2026-05-21-18: SKILL.md prose canonicalization
# for the test-cluster skills (gaia-test-design, gaia-test-strategy,
# gaia-test-framework, gaia-edit-test-plan, gaia-atdd). NARROWED scope:
# SKILL.md only; scripts deferred to AF-21-19 (display-strings-stay-literal
# guardrail per existing vcp-chk-27-28 + vcp-chk-29-30 bats assertions).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "AF-21-18: gaia-test-design/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-test-design/SKILL.md"
}

@test "AF-21-18: gaia-test-strategy/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-test-strategy/SKILL.md"
}

@test "AF-21-18: gaia-test-framework/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-test-framework/SKILL.md"
}

@test "AF-21-18: gaia-edit-test-plan/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-edit-test-plan/SKILL.md"
}

@test "AF-21-18: gaia-atdd/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-atdd/SKILL.md"
}

@test "AF-21-18: all 5 SKILL.md files use canonical .gaia/artifacts/test-artifacts/test-plan.md" {
  for skill in gaia-test-design gaia-test-strategy gaia-test-framework gaia-edit-test-plan; do
    grep -qF '.gaia/artifacts/test-artifacts/' "$PLUGIN_ROOT/skills/$skill/SKILL.md"
  done
}

@test "AF-21-18: gaia-atdd/SKILL.md uses canonical .gaia/artifacts/test-artifacts/atdd-{story_key}.md" {
  grep -qF '.gaia/artifacts/test-artifacts/atdd-' "$PLUGIN_ROOT/skills/gaia-atdd/SKILL.md"
}
