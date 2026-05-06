#!/usr/bin/env bats
# e70-s5-skill-registration.bats — E70-S5 AC8: SKILL.md + manifest registration
#
# Verifies that the three query skills introduced by E70-S5
# (gaia-list-tools, gaia-tool-info, gaia-validate-rubric) ship a SKILL.md
# under plugins/gaia/skills/<name>/ AND appear in both
# knowledge/workflow-manifest.csv and knowledge/gaia-help.csv.
#
# Story: E70-S5
# Refs:  FR-RSV2-21, FR-RSV2-10, NFR-RSV2-4

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILLS_DIR="$PLUGIN_DIR/skills"
WORKFLOW_MANIFEST="$PLUGIN_DIR/knowledge/workflow-manifest.csv"
HELP_MANIFEST="$PLUGIN_DIR/knowledge/gaia-help.csv"

SKILL_NAMES=(gaia-list-tools gaia-tool-info gaia-validate-rubric)

@test "AC8: each skill ships a SKILL.md with a frontmatter name field" {
  for skill in "${SKILL_NAMES[@]}"; do
    [ -f "$SKILLS_DIR/$skill/SKILL.md" ] || { echo "missing SKILL.md for $skill" >&2; return 1; }
    grep -q "^name: $skill\$" "$SKILLS_DIR/$skill/SKILL.md" \
      || { echo "frontmatter name mismatch in $skill/SKILL.md" >&2; return 1; }
    grep -q "^description:" "$SKILLS_DIR/$skill/SKILL.md" \
      || { echo "no description: in $skill/SKILL.md" >&2; return 1; }
  done
}

@test "AC8: each skill is registered in workflow-manifest.csv" {
  for skill in "${SKILL_NAMES[@]}"; do
    grep -q "\"$skill\"" "$WORKFLOW_MANIFEST" \
      || { echo "$skill missing from workflow-manifest.csv" >&2; return 1; }
  done
}

@test "AC8: each skill is registered in gaia-help.csv" {
  for skill in "${SKILL_NAMES[@]}"; do
    grep -q "\"$skill\"" "$HELP_MANIFEST" \
      || { echo "$skill missing from gaia-help.csv" >&2; return 1; }
  done
}
