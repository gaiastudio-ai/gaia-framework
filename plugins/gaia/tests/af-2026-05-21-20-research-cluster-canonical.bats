#!/usr/bin/env bats
# AF-21-20: research-cluster SKILL.md canonical-path migration.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "AF-21-20: gaia-product-brief/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-product-brief/SKILL.md"
}
@test "AF-21-20: gaia-market-research/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-market-research/SKILL.md"
}
@test "AF-21-20: gaia-domain-research/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-domain-research/SKILL.md"
}
@test "AF-21-20: gaia-tech-research/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-tech-research/SKILL.md"
}
@test "AF-21-20: gaia-brainstorm/SKILL.md has zero legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts)' "$PLUGIN_ROOT/skills/gaia-brainstorm/SKILL.md"
}
@test "AF-21-20: canonical creative-artifacts and planning-artifacts paths present" {
  grep -qF '.gaia/artifacts/creative-artifacts/product-brief-' "$PLUGIN_ROOT/skills/gaia-product-brief/SKILL.md"
  grep -qF '.gaia/artifacts/creative-artifacts/brainstorm' "$PLUGIN_ROOT/skills/gaia-brainstorm/SKILL.md"
  grep -qF '.gaia/artifacts/planning-artifacts/' "$PLUGIN_ROOT/skills/gaia-market-research/SKILL.md"
}
