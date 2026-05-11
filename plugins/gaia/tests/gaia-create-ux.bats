#!/usr/bin/env bats
# gaia-create-ux.bats — E28-S43 tests for the gaia-create-ux native skill
#
# Validates:
#   AC1: SKILL.md exists with Cluster 5 frontmatter (name, description)
#   AC2: ux-design-assessment-template.md carried into skill directory
#   AC3: Cluster 4 scripts/setup.sh + scripts/finalize.sh exist and source foundation
#   AC4: ux-designer subagent invocation present (no inline persona)
#   AC5: Frontmatter linter exits zero

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-ux"

setup() {
  common_setup
}
teardown() { common_teardown; }

# ---------- AC1: Frontmatter ----------

@test "AC1: SKILL.md exists in gaia-create-ux skill directory" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "AC1: frontmatter contains name: gaia-create-ux" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-create-ux"* ]]
}

@test "AC1: frontmatter contains description field" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"description:"* ]]
}

@test "AC1: frontmatter declares orchestration_class (post-ADR-093)" {
  # ADR-093 / E84-S3: `context: fork` stripped from non-reviewer plugin
  # SKILL.md. gaia-create-ux is heavy-procedural.
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"orchestration_class: heavy-procedural"* ]]
}

@test "AC1: frontmatter contains allowed-tools" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"allowed-tools:"* ]]
}

# ---------- AC2: Template carried into skill directory ----------

@test "AC2: ux-design-assessment-template.md exists in skill directory" {
  [ -f "$SKILL_DIR/ux-design-assessment-template.md" ]
}

@test "AC2: SKILL.md references ux-design-assessment-template.md" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"ux-design-assessment-template.md"* ]]
}

@test "AC2: ux-design-assessment-template.md contains UX Assessment section headers" {
  run cat "$SKILL_DIR/ux-design-assessment-template.md"
  [[ "$output" == *"## 1. UX Overview"* ]]
  [[ "$output" == *"## 5. Accessibility Assessment"* ]]
}

# ---------- AC3: Shared scripts exist ----------

@test "AC3: scripts/setup.sh exists in gaia-create-ux" {
  [ -f "$SKILL_DIR/scripts/setup.sh" ]
}

@test "AC3: scripts/finalize.sh exists in gaia-create-ux" {
  [ -f "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "AC3: setup.sh is executable" {
  [ -x "$SKILL_DIR/scripts/setup.sh" ]
}

@test "AC3: finalize.sh is executable" {
  [ -x "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "AC3: setup.sh sources resolve-config.sh" {
  run cat "$SKILL_DIR/scripts/setup.sh"
  [[ "$output" == *"resolve-config.sh"* ]]
}

@test "AC3: finalize.sh sources checkpoint.sh" {
  run cat "$SKILL_DIR/scripts/finalize.sh"
  [[ "$output" == *"checkpoint.sh"* ]]
}

@test "AC3: setup.sh uses set -euo pipefail" {
  run cat "$SKILL_DIR/scripts/setup.sh"
  [[ "$output" == *"set -euo pipefail"* ]]
}

@test "AC3: finalize.sh uses set -euo pipefail" {
  run cat "$SKILL_DIR/scripts/finalize.sh"
  [[ "$output" == *"set -euo pipefail"* ]]
}

# ---------- AC4: Subagent routing ----------

@test "AC4: SKILL.md delegates to ux-designer subagent" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"ux-designer"* ]]
}

@test "AC4: SKILL.md does not contain inline persona content" {
  run cat "$SKILL_DIR/SKILL.md"
  # Should reference the subagent, not embed Christy's full persona
  [[ "$output" != *"You are Christy"* ]]
}

@test "AC4: SKILL.md routes via agents/ux-designer" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"agents/ux-designer"* ]]
}

# ---------- AC5: Multi-step reasoning preserved from legacy workflow ----------

@test "AC5: SKILL.md contains Step 1 — Load PRD" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Load PRD"* ]]
}

@test "AC5: SKILL.md contains User Personas step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"User Personas"* ]]
}

@test "AC5: SKILL.md contains Information Architecture step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Information Architecture"* ]]
}

@test "AC5: SKILL.md contains Wireframes step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Wireframes"* ]]
}

@test "AC5: SKILL.md contains Interaction Patterns step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Interaction Patterns"* ]]
}

@test "AC5: SKILL.md contains Accessibility step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Accessibility"* ]]
}

@test "AC5: SKILL.md contains Generate Output step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Generate Output"* ]]
}

# ---------- AC5: Frontmatter linter ----------

@test "AC5: frontmatter linter passes on gaia-create-ux/SKILL.md" {
  cd "$BATS_TEST_DIRNAME/../../.."
  run bash .github/scripts/lint-skill-frontmatter.sh
  [ "$status" -eq 0 ]
}
