#!/usr/bin/env bats
# AF-2026-05-22-4: canonicalize _memory/<agent>-sidecar/ → .gaia/memory/<agent>-sidecar/
# in SKILL.md prose.
#
# Bug reported during /gaia-create-arch dogfooding: architecture-decisions.md
# wrote to legacy _memory/architect-sidecar/ instead of canonical
# .gaia/memory/architect-sidecar/ because the SKILL.md prose hardcoded the
# legacy path (lines 304, 315, 326). The script (auto-save-memory.sh +
# memory-writer.sh) already routes to canonical, but the LLM follows the
# SKILL.md instructions literally.
#
# This sweep canonicalizes ~35 SKILL.md files. .sh scripts were NOT swept
# (they implement canonical-first resolvers and naive replacement broke
# their fallback control flow).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "AF-22-4: gaia-create-arch SKILL.md architecture-decisions writes to canonical .gaia/memory/" {
  grep -qF '.gaia/memory/architect-sidecar/architecture-decisions.md' "$PLUGIN_ROOT/skills/gaia-create-arch/SKILL.md"
  # No remaining bare-legacy reference to the architect sidecar
  ! grep -qF '_memory/architect-sidecar/architecture-decisions.md' "$PLUGIN_ROOT/skills/gaia-create-arch/SKILL.md"
}

@test "AF-22-4: gaia-meeting SKILL.md sidecar paths canonical" {
  grep -qF '.gaia/memory/{agent}-sidecar' "$PLUGIN_ROOT/skills/gaia-meeting/SKILL.md"
}

@test "AF-22-4: gaia-brownfield SKILL.md sidecar writes canonical" {
  grep -qF '.gaia/memory/architect-sidecar/ground-truth.md' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  grep -qF '.gaia/memory/validator-sidecar/ground-truth.md' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
}

@test "AF-22-4: gaia-memory-hygiene SKILL.md main-context read target canonical (with legacy fallback noted)" {
  grep -qF '.gaia/memory/' "$PLUGIN_ROOT/skills/gaia-memory-hygiene/SKILL.md"
  # AC-EC10 graceful-degradation messages still reference _memory/ as the
  # legacy directory — those are user-facing strings about pre-migration
  # state and remain intentional. Verify the contract still mentions both.
  grep -qF 'fallback' "$PLUGIN_ROOT/skills/gaia-memory-hygiene/SKILL.md"
}

@test "AF-22-4: gaia-fix-story validator-sidecar read canonical" {
  grep -qF '.gaia/memory/validator-sidecar' "$PLUGIN_ROOT/skills/gaia-fix-story/SKILL.md"
}

@test "AF-22-4: gaia-sprint-status validator-sidecar decision-log canonical" {
  grep -qF '.gaia/memory/validator-sidecar/decision-log.md' "$PLUGIN_ROOT/skills/gaia-sprint-status/SKILL.md"
}

@test "AF-22-4: .sh resolvers use canonical .gaia/memory only (AF-2026-05-27-3 — legacy fallback removed)" {
  # AF-2026-05-27-3 (ADR-111): the `[ -d _memory ] && [ ! -d .gaia/memory ]`
  # smart-fallback idiom was REMOVED from the resolvers. Verify it is gone and
  # the canonical .gaia/memory resolution is present.
  ! grep -qF '[ -d "_memory" ] && [ ! -d ".gaia/memory" ]' "$PLUGIN_ROOT/scripts/lib/auto-save-memory.sh"
  ! grep -qF '[ -d "_memory" ] && [ ! -d ".gaia/memory" ]' "$PLUGIN_ROOT/scripts/memory-writer.sh"
  grep -qF '.gaia/memory' "$PLUGIN_ROOT/scripts/lib/auto-save-memory.sh"
  grep -qF '.gaia/memory' "$PLUGIN_ROOT/scripts/memory-writer.sh"
}

@test "AF-22-4: dual-layout caveats preserved (lines mentioning both legacy + canonical)" {
  # Some lines were preserved BY DESIGN because they mention both
  # _memory/ and .gaia/memory/ (dual-layout caveat for pre-migration).
  grep -q "legacy" "$PLUGIN_ROOT/skills/gaia-memory-hygiene/SKILL.md"
}

@test "AF-22-4: framework-wide — no bare _memory/<agent>-sidecar write targets in SKILL.md prose" {
  # Allowlist: lines mentioning "legacy" or "fallback" near the path are intentional.
  # Use grep -v to filter those out, then assert no remaining bare-legacy hits.
  run bash -c "grep -rnE '_memory/[a-z-]+-sidecar' \"$PLUGIN_ROOT/skills/\" --include='SKILL.md' 2>/dev/null | grep -vEi 'legacy|fallback|pre-adr-111|pre-migration|back-compat' || true"
  # Empty output = zero remaining bare-legacy hits = pass
  [ -z "$output" ]
}
