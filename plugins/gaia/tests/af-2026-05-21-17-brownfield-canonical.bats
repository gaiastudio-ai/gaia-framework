#!/usr/bin/env bats
# af-2026-05-21-17-brownfield-canonical.bats
#
# Regression coverage for AF-2026-05-21-17: /gaia-brownfield SKILL.md
# hardcoded 49 legacy docs/planning-artifacts/ and docs/test-artifacts/
# paths across the Phase 2 brownfield artifact set.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BROWNFIELD_SKILL="$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
}

teardown() { common_teardown; }

@test "gaia-brownfield/SKILL.md uses canonical .gaia/artifacts/planning-artifacts/ paths" {
  grep -qF '.gaia/artifacts/planning-artifacts/brownfield-assessment.md' "$BROWNFIELD_SKILL"
  grep -qF '.gaia/artifacts/planning-artifacts/project-documentation.md' "$BROWNFIELD_SKILL"
  grep -qF '.gaia/artifacts/planning-artifacts/api-documentation.md' "$BROWNFIELD_SKILL"
}

@test "gaia-brownfield/SKILL.md uses canonical .gaia/artifacts/test-artifacts/ paths" {
  grep -qF '.gaia/artifacts/test-artifacts/' "$BROWNFIELD_SKILL"
}

@test "gaia-brownfield/SKILL.md has zero remaining legacy docs/ literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts)' "$BROWNFIELD_SKILL"
}

@test "gaia-brownfield/SKILL.md Mission paragraph documents canonical destinations" {
  grep -qF 'all target canonical destinations' "$BROWNFIELD_SKILL"
  grep -qF 'Path resolution' "$BROWNFIELD_SKILL"
}
