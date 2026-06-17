#!/usr/bin/env bats
# af-2026-05-21-13-epics-canonical.bats
#
# Regression coverage for AF-2026-05-21-13: /gaia-create-epics and
# /gaia-add-stories SKILL.md prose hardcoded legacy docs/planning-artifacts/
# and docs/test-artifacts/ literals. The LLM, when writing artifacts via the
# Write tool, used the prose-named legacy paths. Greenfield + post-ADR-111
# projects landed artifacts in rogue docs/ directories.
#
# Note: The scripts (gaia-create-epics/scripts/finalize.sh and
# gaia-add-stories/scripts/setup.sh) ALREADY implement an E96-S7 partial-4c
# canonical-first two-tier smart-fallback — they read from canonical first
# and fall back to legacy only when canonical is absent. The bug surface
# was ONLY in the SKILL.md prose. This fixture verifies (a) the SKILL.md
# prose canonical assertion and (b) the existing canonical-first script
# resolution remains intact (regression guard against drift).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CREATE_EPICS_SKILL="$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
  ADD_STORIES_SKILL="$PLUGIN_ROOT/skills/gaia-add-stories/SKILL.md"
  CREATE_EPICS_FINALIZE="$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
  ADD_STORIES_SETUP="$PLUGIN_ROOT/skills/gaia-add-stories/scripts/setup.sh"
}

teardown() { common_teardown; }

# --- SKILL.md prose canonical assertions ---

@test "gaia-create-epics/SKILL.md write-path prose uses canonical .gaia/ paths" {
  # Primary write target (epics-and-stories.md) MUST be canonical
  grep -qF '.gaia/artifacts/planning-artifacts/epics-and-stories.md' "$CREATE_EPICS_SKILL"
  # Cross-references to PRD, architecture, test-plan MUST be canonical
  grep -qF '.gaia/artifacts/planning-artifacts/prd.md' "$CREATE_EPICS_SKILL"
  grep -qF '.gaia/artifacts/planning-artifacts/architecture.md' "$CREATE_EPICS_SKILL"
  grep -qF '.gaia/artifacts/test-artifacts/test-plan.md' "$CREATE_EPICS_SKILL"
}

@test "gaia-create-epics/SKILL.md sharded-fallback uses canonical roots" {
  # Sharded PRD form must also be canonical
  grep -qF '.gaia/artifacts/planning-artifacts/prd/prd.md' "$CREATE_EPICS_SKILL"
  # Sharded test-plan index must be canonical
  grep -qF '.gaia/artifacts/test-artifacts/test-plan/index.md' "$CREATE_EPICS_SKILL"
}

@test "gaia-create-epics/SKILL.md brownfield-onboarding.md write-path is canonical" {
  # Line 188 establishes canonical destination for brownfield onboarding artifact
  grep -qF '.gaia/artifacts/planning-artifacts/brownfield-onboarding.md' "$CREATE_EPICS_SKILL"
}

@test "gaia-create-epics/SKILL.md has no remaining legacy docs/ write-path literals" {
  # All literals MUST be canonical; the post-edit Mission paragraph names only
  # `.gaia/artifacts/...` canonical paths (the prose talks about pre-ADR-111
  # fallback in abstract terms without naming a `docs/` literal).
  ! grep -qE 'docs/(planning-artifacts|test-artifacts)' "$CREATE_EPICS_SKILL"
}

@test "gaia-add-stories/SKILL.md write-path prose uses canonical .gaia/ paths" {
  grep -qF '.gaia/artifacts/planning-artifacts/epics-and-stories.md' "$ADD_STORIES_SKILL"
  grep -qF '.gaia/artifacts/planning-artifacts/architecture.md' "$ADD_STORIES_SKILL"
  grep -qF '.gaia/artifacts/planning-artifacts/prd.md' "$ADD_STORIES_SKILL"
}

@test "gaia-add-stories/SKILL.md test-plan strategy-fallback uses canonical roots" {
  # Both flat and strategy/ forms must be canonical
  grep -qF '.gaia/artifacts/test-artifacts/test-plan.md' "$ADD_STORIES_SKILL"
  grep -qF '.gaia/artifacts/test-artifacts/strategy/test-plan.md' "$ADD_STORIES_SKILL"
}

@test "gaia-add-stories/SKILL.md has no remaining legacy docs/ write-path literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts)' "$ADD_STORIES_SKILL"
}

# --- Regression guards: existing canonical-first script resolution intact ---

@test "gaia-create-epics/scripts/finalize.sh retains canonical-first ARTIFACT resolution" {
  # The script's existing two-tier smart-fallback MUST stay intact — this AF
  # does not modify scripts. Drift would be caught here. Match on the
  # executable `if [ -f ... ]` line, not docstrings, to assert canonical
  # appears in the IF branch and legacy in the ELIF branch.
  grep -qE 'if \[ -f "\.gaia/artifacts/planning-artifacts/epics-and-stories\.md" \]' "$CREATE_EPICS_FINALIZE"
  grep -qE 'elif \[ -f "docs/planning-artifacts/epics-and-stories\.md" \]' "$CREATE_EPICS_FINALIZE"
}

@test "gaia-add-stories/scripts/setup.sh retains canonical-first PLANNING_ARTIFACTS resolution" {
  # Assert the existing canonical-first two-tier resolution: canonical assignment
  # appears in an `if [ -d ... ]; then` branch and legacy is the `else` fallback.
  grep -qE '\.gaia/artifacts/planning-artifacts' "$ADD_STORIES_SETUP"
  grep -qE 'docs/planning-artifacts' "$ADD_STORIES_SETUP"
  # Within executable code (not docstrings), the canonical assignment is reached
  # FIRST in control flow. We verify by line ordering for assignment lines only.
  local gaia_assign legacy_assign
  gaia_assign=$(grep -nE '^[[:space:]]+(PLANNING_ARTIFACTS|[A-Z_]+)=.*\.gaia/artifacts/planning-artifacts' "$ADD_STORIES_SETUP" | head -1 | cut -d: -f1)
  legacy_assign=$(grep -nE '^[[:space:]]+(PLANNING_ARTIFACTS|[A-Z_]+)=.*docs/planning-artifacts' "$ADD_STORIES_SETUP" | head -1 | cut -d: -f1)
  [ -n "$gaia_assign" ]
  [ -n "$legacy_assign" ]
  [ "$gaia_assign" -lt "$legacy_assign" ]
}
