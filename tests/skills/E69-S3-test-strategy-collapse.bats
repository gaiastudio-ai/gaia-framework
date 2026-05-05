#!/usr/bin/env bats
# E69-S3-test-strategy-collapse.bats — gaia-test-strategy collapse validation
#
# Validates the collapse of two test-related skills into one canonical skill,
# per FR-RSV2-24, source-report §9.4, ADR-077:
#
#   gaia-test-design     -> deprecated, replaced_by gaia-test-strategy --plan
#   gaia-test-framework  -> deprecated, replaced_by gaia-test-strategy --scaffold
#
# Surfaces:
#   - new SKILL.md at plugins/gaia/skills/gaia-test-strategy/SKILL.md
#   - retired frontmatter on the two old SKILL.md files
#   - gaia-help.csv: removed old rows, added test-strategy row
#   - workflow-manifest.csv: removed old rows, added test-strategy row
#
# Pattern mirrors tests/skills/E69-S1-rename-map.bats (E69-S1 precedent).
#
# Usage: bats tests/skills/E69-S3-test-strategy-collapse.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  KNOWLEDGE_DIR="$REPO_ROOT/plugins/gaia/knowledge"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  HELP_CSV="$KNOWLEDGE_DIR/gaia-help.csv"
  MANIFEST_CSV="$KNOWLEDGE_DIR/workflow-manifest.csv"
  STRATEGY_SKILL="$SKILLS_DIR/gaia-test-strategy/SKILL.md"
  DESIGN_SKILL="$SKILLS_DIR/gaia-test-design/SKILL.md"
  FRAMEWORK_SKILL="$SKILLS_DIR/gaia-test-framework/SKILL.md"
}

# Helper: read frontmatter (between first two `---` markers)
read_frontmatter() {
  awk '/^---$/{n++; if (n==2) exit; next} n==1{print}' "$1"
}

# ---------- AC1: gaia-test-strategy SKILL.md exists with correct frontmatter ----------

@test "AC1: gaia-test-strategy/SKILL.md exists" {
  [ -f "$STRATEGY_SKILL" ]
}

@test "AC1: gaia-test-strategy SKILL.md has name: gaia-test-strategy" {
  read_frontmatter "$STRATEGY_SKILL" | grep -q "^name: gaia-test-strategy$"
}

@test "AC1: gaia-test-strategy SKILL.md description covers both plan and scaffold" {
  read_frontmatter "$STRATEGY_SKILL" | grep -Eq "(strategy|plan).*(scaffold|framework)|(scaffold|framework).*(strategy|plan)"
}

# ---------- AC2: --plan mode delegates to Sable / outputs test-strategy.md ----------

@test "AC2: SKILL.md body mentions --plan mode" {
  grep -q "\-\-plan" "$STRATEGY_SKILL"
}

@test "AC2: SKILL.md body delegates --plan to test-architect (Sable)" {
  grep -Eq "test-architect|Sable" "$STRATEGY_SKILL"
}

@test "AC2: SKILL.md body references test-strategy.md output path" {
  grep -q "docs/test-artifacts/strategy/test-strategy.md" "$STRATEGY_SKILL"
}

# ---------- AC3: --scaffold mode generates scaffolding ----------

@test "AC3: SKILL.md body mentions --scaffold mode" {
  grep -q "\-\-scaffold" "$STRATEGY_SKILL"
}

@test "AC3: SKILL.md body mentions --service flag" {
  grep -q "\-\-service" "$STRATEGY_SKILL"
}

@test "AC3: SKILL.md body mentions --add flag" {
  grep -q "\-\-add" "$STRATEGY_SKILL"
}

# ---------- AC4: No-parameter interactive mode (4 options) ----------

@test "AC4: SKILL.md body shows 4-option interactive prompt" {
  # The four options should be visible in the no-parameter mode body
  grep -q "test strategy" "$STRATEGY_SKILL"
  grep -q "Scaffold" "$STRATEGY_SKILL"
  grep -Eq "Add.*test type" "$STRATEGY_SKILL"
  grep -Eq "Show.*test setup|current test setup" "$STRATEGY_SKILL"
}

# ---------- AC5: gaia-help.csv and workflow-manifest.csv entries ----------

@test "AC5: gaia-help.csv has gaia-test-strategy row" {
  awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-test-strategy"'
}

@test "AC5: gaia-help.csv no longer has gaia-test-design as primary command" {
  ! awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-test-design"'
}

@test "AC5: gaia-help.csv no longer has gaia-test-framework as primary command" {
  ! awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-test-framework"'
}

@test "AC5: workflow-manifest.csv has gaia-test-strategy row" {
  awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-test-strategy"'
}

@test "AC5: workflow-manifest.csv no longer has gaia-test-design as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-test-design"'
}

@test "AC5: workflow-manifest.csv no longer has gaia-test-framework as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-test-framework"'
}

@test "AC5: gaia-help.csv test-strategy row has phase setup (anytime)" {
  awk -F',' '$5=="\"gaia-test-strategy\""{print $2}' "$HELP_CSV" | grep -Eq '"(setup|anytime)"'
}

@test "AC5: workflow-manifest.csv test-strategy row has phase setup" {
  # workflow-manifest column 5 is phase
  awk -F',' '$7=="\"gaia-test-strategy\""{print $5}' "$MANIFEST_CSV" | grep -q '"setup"'
}

# ---------- AC6: Deprecation aliases on gaia-test-strategy SKILL.md ----------

@test "AC6: gaia-test-strategy SKILL.md has deprecated_aliases listing both old names" {
  read_frontmatter "$STRATEGY_SKILL" | grep -E "^deprecated_aliases:" | grep -q "gaia-test-design"
  read_frontmatter "$STRATEGY_SKILL" | grep -E "^deprecated_aliases:" | grep -q "gaia-test-framework"
}

@test "AC6: gaia-test-strategy SKILL.md has deprecated_since marker" {
  read_frontmatter "$STRATEGY_SKILL" | grep -q "^deprecated_since:"
}

# ---------- AC10: Old SKILL.md files retired ----------

@test "AC10: gaia-test-design SKILL.md no longer has name: gaia-test-design (retired)" {
  ! read_frontmatter "$DESIGN_SKILL" | grep -q "^name: gaia-test-design$"
}

@test "AC10: gaia-test-design SKILL.md has replaced_by: gaia-test-strategy" {
  read_frontmatter "$DESIGN_SKILL" | grep -q "^replaced_by: gaia-test-strategy$"
}

@test "AC10: gaia-test-design SKILL.md has deprecated_since marker" {
  read_frontmatter "$DESIGN_SKILL" | grep -q "^deprecated_since:"
}

@test "AC10: gaia-test-framework SKILL.md no longer has name: gaia-test-framework (retired)" {
  ! read_frontmatter "$FRAMEWORK_SKILL" | grep -q "^name: gaia-test-framework$"
}

@test "AC10: gaia-test-framework SKILL.md has replaced_by: gaia-test-strategy" {
  read_frontmatter "$FRAMEWORK_SKILL" | grep -q "^replaced_by: gaia-test-strategy$"
}

@test "AC10: gaia-test-framework SKILL.md has deprecated_since marker" {
  read_frontmatter "$FRAMEWORK_SKILL" | grep -q "^deprecated_since:"
}

# ---------- AC-EC1: Single-stack project skips picker ----------

@test "AC-EC1: SKILL.md body documents single-stack picker skip" {
  grep -Eq "single[- ]stack|one stack|single declared stack" "$STRATEGY_SKILL"
}

# ---------- AC-EC2: Missing project-config.yaml ----------

@test "AC-EC2: SKILL.md body documents missing project-config guard" {
  grep -q "project-config.yaml" "$STRATEGY_SKILL"
  grep -Eq "/gaia-init|/gaia-brownfield" "$STRATEGY_SKILL"
}

# ---------- AC-EC3: --plan and --scaffold mutually exclusive ----------

@test "AC-EC3: SKILL.md body documents --plan / --scaffold mutual exclusion" {
  grep -Eq "mutually exclusive|mutual.exclusion" "$STRATEGY_SKILL"
}

# ---------- Help intent keywords (AC5) ----------

@test "AC5: gaia-help.csv test-strategy row has keywords covering strategy, design, framework" {
  awk -F',' '$5=="\"gaia-test-strategy\""' "$HELP_CSV" | grep -Eiq "test.strategy|test.design|test.framework|scaffold"
}
