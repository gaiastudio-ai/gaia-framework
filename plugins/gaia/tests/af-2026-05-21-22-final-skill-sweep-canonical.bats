#!/usr/bin/env bats
# AF-21-22: final 10-skill SKILL.md sweep.
# gaia-run-all-reviews retains 3 dual-layout caveat refs (legacy + canonical).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "AF-21-22: gaia-memory-hygiene/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-memory-hygiene/SKILL.md"
}
@test "AF-21-22: gaia-correct-course/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-correct-course/SKILL.md"
}
@test "AF-21-22: gaia-sprint-close/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-sprint-close/SKILL.md"
}
@test "AF-21-22: gaia-security-review/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-security-review/SKILL.md"
}
@test "AF-21-22: gaia-nfr/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-nfr/SKILL.md"
}
@test "AF-21-22: gaia-code-review-standards/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-code-review-standards/SKILL.md"
}
@test "AF-21-22: gaia-quick-spec/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-quick-spec/SKILL.md"
}
@test "AF-21-22: gaia-problem-solving/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-problem-solving/SKILL.md"
}
@test "AF-21-22: gaia-fill-test-gaps/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-fill-test-gaps/SKILL.md"
}
@test "AF-21-22: gaia-run-all-reviews/SKILL.md only intentional dual-layout caveat refs (line 178 ADR-111 explanation)" {
  # 3 intentional caveats remain (lines 26, 67, 178 — explain dual-layout for ADR-070/ADR-111)
  local hits
  hits=$(grep -cE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-run-all-reviews/SKILL.md")
  [ "$hits" -le 3 ]
}
