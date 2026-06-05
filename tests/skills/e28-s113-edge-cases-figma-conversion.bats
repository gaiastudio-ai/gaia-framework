#!/usr/bin/env bats
# e28-s113-edge-cases-figma-conversion.bats — E28-S113 acceptance tests
#
# Validates the conversion of the legacy `_gaia/dev/skills/edge-cases.md`
# and `_gaia/dev/skills/figma-integration.md` dev skills to native
# Claude Code SKILL.md format under `plugins/gaia/skills/`, with an
# enterprise license gate applied to the figma-integration OSS stub.
#
# Traces to FR-323, FR-332, NFR-048, NFR-053, ADR-041, ADR-043.
#
# Dependencies: bats-core 1.10+

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  EDGE_SKILL="$REPO_ROOT/plugins/gaia/skills/edge-cases/SKILL.md"
  FIGMA_SKILL="$REPO_ROOT/plugins/gaia/skills/figma-integration/SKILL.md"
  LINTER="$REPO_ROOT/.github/scripts/lint-skill-frontmatter.sh"
  LEGACY_EDGE="$REPO_ROOT/../_gaia/dev/skills/edge-cases.md"
}

# ---------- AC5: Directory placement ----------

@test "AC5: edge-cases SKILL.md lives under plugins/gaia/skills/edge-cases/" {
  [ -f "$EDGE_SKILL" ]
}

@test "AC5: figma-integration SKILL.md lives under plugins/gaia/skills/figma-integration/" {
  [ -f "$FIGMA_SKILL" ]
}

@test "AC5: no stray SKILL.md files at plugins/gaia/skills/ root level" {
  [ ! -f "$REPO_ROOT/plugins/gaia/skills/SKILL.md" ]
}

# ---------- AC1: edge-cases frontmatter ----------

@test "AC1: edge-cases SKILL.md has name field in frontmatter" {
  grep -qE '^name:[[:space:]]*[^[:space:]]+' "$EDGE_SKILL"
}

@test "AC1: edge-cases SKILL.md has description field in frontmatter" {
  grep -qE '^description:[[:space:]]*[^[:space:]]+' "$EDGE_SKILL"
}

@test "AC1: edge-cases SKILL.md has version field in frontmatter" {
  grep -qE '^version:[[:space:]]*' "$EDGE_SKILL"
}

@test "AC1: edge-cases SKILL.md preserves original sectioned_loading markers" {
  # Original skill has these SECTION markers — all must be preserved.
  local sections=(overview when-to-invoke input-contract output-schema analysis-heuristics token-budget failure-handling usage-example notes)
  for section in "${sections[@]}"; do
    grep -qE "<!-- SECTION: ${section} -->" "$EDGE_SKILL" || return 1
  done
}

# ---------- AC6: JIT callable contract preserved ----------

@test "AC6: edge-cases SKILL.md retains Input Contract section" {
  grep -qE '^## Input Contract' "$EDGE_SKILL"
}

@test "AC6: edge-cases SKILL.md retains Output Schema section" {
  grep -qE '^## Output Schema' "$EDGE_SKILL"
}

@test "AC6: edge-cases SKILL.md retains Failure and Timeout Handling section" {
  grep -qE '^## Failure' "$EDGE_SKILL"
}

@test "AC6: edge-cases SKILL.md preserves edge_case_results output variable name" {
  grep -q 'edge_case_results' "$EDGE_SKILL"
}

# ---------- AC2: figma-integration stub frontmatter ----------

@test "AC2: figma-integration SKILL.md has name field" {
  grep -qE '^name:[[:space:]]*[^[:space:]]+' "$FIGMA_SKILL"
}

@test "AC2: figma-integration SKILL.md has description field" {
  grep -qE '^description:[[:space:]]*[^[:space:]]+' "$FIGMA_SKILL"
}

@test "AC2: figma-integration SKILL.md has license: enterprise field" {
  grep -qE '^license:[[:space:]]*enterprise' "$FIGMA_SKILL"
}

@test "AC2: figma-integration SKILL.md has feature_flag: figma-premium field" {
  grep -qE '^feature_flag:[[:space:]]*figma-premium' "$FIGMA_SKILL"
}

# ---------- AC3: Stub body points to enterprise plugin, no premium logic ----------

@test "AC3: figma-integration stub documents the enterprise-plugin boundary" {
  grep -qiE "enterprise plugin|figma-premium|premium" "$FIGMA_SKILL"
}

@test "AC3: figma-integration stub does NOT contain premium extraction logic — no figma/get_styles" {
  ! grep -qE 'figma/get_styles|figma/get_components|figma/get_file' "$FIGMA_SKILL"
}

@test "AC3: figma-integration stub does NOT contain W3C DTCG extraction details" {
  ! grep -qE 'W3C DTCG' "$FIGMA_SKILL"
}

@test "AC3: figma-integration stub does NOT contain per-stack resolution table" {
  ! grep -qE 'Per-Stack Token Resolution' "$FIGMA_SKILL"
}

# ---------- AC4: Linter passes for both files ----------

@test "AC4: frontmatter linter returns exit 0 for the plugins/gaia/skills tree" {
  cd "$REPO_ROOT"
  run bash "$LINTER"
  [ "$status" -eq 0 ]
  [[ "$output" != *ERROR* ]]
}
