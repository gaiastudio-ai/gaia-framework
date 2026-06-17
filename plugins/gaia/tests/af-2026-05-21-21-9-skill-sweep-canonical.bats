#!/usr/bin/env bats
# AF-21-21: 9-skill SKILL.md sweep. Test-automate retains 3 docs/ refs in
# intentional caveats ("Do NOT inline-hardcode the docs/ glob") per Val W3.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "gaia-readiness-check/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-readiness-check/SKILL.md"
}
@test "gaia-sprint-plan/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-sprint-plan/SKILL.md"
}
@test "gaia-add-feature/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-add-feature/SKILL.md"
}
@test "gaia-retro/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-retro/SKILL.md"
}
@test "gaia-infra-design/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-infra-design/SKILL.md"
}
@test "gaia-test-automate/SKILL.md only legacy refs are in intentional caveats" {
  # 3 intentional caveats remain (lines 27, 179, 278) — 'Do NOT inline-hardcode docs/ glob'
  local hits
  hits=$(grep -cE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-test-automate/SKILL.md")
  [ "$hits" -le 3 ]
}
@test "gaia-triage-findings/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-triage-findings/SKILL.md"
}
@test "gaia-document-rulesets/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-document-rulesets/SKILL.md"
}
@test "gaia-tech-debt-review/SKILL.md zero legacy hits" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-tech-debt-review/SKILL.md"
}
