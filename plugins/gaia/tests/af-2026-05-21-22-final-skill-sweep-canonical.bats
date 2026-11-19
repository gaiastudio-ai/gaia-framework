#!/usr/bin/env bats
# Final 10-skill SKILL.md sweep — asserts zero legacy docs/ artifact path
# literals in skills that have been migrated to the canonical .gaia/ layout.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "gaia-memory-hygiene/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-memory-hygiene/SKILL.md"
}
@test "gaia-correct-course/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-correct-course/SKILL.md"
}
@test "gaia-sprint-close/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-sprint-close/SKILL.md"
}
@test "gaia-security-review/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-security-review/SKILL.md"
}
@test "gaia-nfr/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-nfr/SKILL.md"
}
@test "gaia-code-review-standards/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-code-review-standards/SKILL.md"
}
@test "gaia-quick-spec/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-quick-spec/SKILL.md"
}
@test "gaia-problem-solving/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-problem-solving/SKILL.md"
}
@test "gaia-fill-test-gaps/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-fill-test-gaps/SKILL.md"
}
@test "gaia-run-all-reviews/SKILL.md zero legacy refs" {
  local hits
  hits=$(grep -cE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-run-all-reviews/SKILL.md" 2>/dev/null || true)
  [ "${hits:-0}" -eq 0 ]
}
