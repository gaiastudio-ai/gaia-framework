#!/usr/bin/env bats
# gaia-edit-ux.bats — E28-S43 tests for the gaia-edit-ux native skill
#
# Validates:
#   AC1: SKILL.md exists with Cluster 5 frontmatter (name, description)
#   AC3: Cluster 4 scripts/setup.sh + scripts/finalize.sh exist and source foundation
#   AC4: ux-designer subagent invocation + cascade-aware edit semantics preserved
#   AC5: Frontmatter linter exits zero

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-edit-ux"

setup() {
  common_setup
}
teardown() { common_teardown; }

# ---------- AC1: Frontmatter ----------

@test "AC1: SKILL.md exists in gaia-edit-ux skill directory" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "AC1: frontmatter contains name: gaia-edit-ux" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-edit-ux"* ]]
}

@test "AC1: frontmatter contains description field" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"description:"* ]]
}

@test "AC1: frontmatter declares orchestration_class (post-ADR-093)" {
  # ADR-093 / E84-S3: `context: fork` stripped from non-reviewer plugin
  # SKILL.md. gaia-edit-ux is heavy-procedural.
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"orchestration_class: heavy-procedural"* ]]
}

@test "AC1: frontmatter contains allowed-tools" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"allowed-tools:"* ]]
}

# ---------- AC3: Shared scripts exist ----------

@test "AC3: scripts/setup.sh exists in gaia-edit-ux" {
  [ -f "$SKILL_DIR/scripts/setup.sh" ]
}

@test "AC3: scripts/finalize.sh exists in gaia-edit-ux" {
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

# ---------- AC4: Subagent routing + cascade semantics ----------

@test "AC4: SKILL.md delegates to ux-designer subagent" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"ux-designer"* ]]
}

@test "AC4: SKILL.md does not contain inline persona content" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" != *"You are Christy"* ]]
}

@test "AC4: SKILL.md routes via agents/ux-designer" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"agents/ux-designer"* ]]
}

@test "AC4: SKILL.md contains cascade impact check" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Cascade"* ]] || [[ "$output" == *"cascade"* ]]
}

@test "AC4: SKILL.md references downstream artifacts" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"architecture.md"* ]]
}

# ---------- AC4: Edit-specific legacy semantics ----------

@test "AC4: SKILL.md contains Load Existing UX Design step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Load Existing UX Design"* ]] || [[ "$output" == *"Load UX Design"* ]]
}

@test "AC4: SKILL.md contains Identify Changes step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Identify Changes"* ]]
}

@test "AC4: SKILL.md contains Apply Edits step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Apply Edits"* ]]
}

@test "AC4: SKILL.md contains Version Note step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Version Note"* ]] || [[ "$output" == *"version note"* ]]
}

@test "AC4: SKILL.md contains Adversarial Review step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Adversarial Review"* ]] || [[ "$output" == *"adversarial"* ]]
}

@test "AC4: SKILL.md preserves cascade impact classifications" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"NONE"* ]]
  [[ "$output" == *"MINOR"* ]]
  [[ "$output" == *"SIGNIFICANT"* ]]
}

# ---------- AC5: Frontmatter linter ----------

@test "AC5: frontmatter linter passes on gaia-edit-ux/SKILL.md" {
  cd "$BATS_TEST_DIRNAME/../../.."
  run bash .github/scripts/lint-skill-frontmatter.sh
  [ "$status" -eq 0 ]
}
