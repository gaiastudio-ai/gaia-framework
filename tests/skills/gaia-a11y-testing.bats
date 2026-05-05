#!/usr/bin/env bats
# gaia-a11y-testing.bats — accessibility-testing skill structural tests (E28-S88)
#
# Validates:
#   AC1: SKILL.md exists with valid YAML frontmatter and WCAG 2.1 content
#   AC5: setup.sh/finalize.sh follow shared pattern (resolve-config.sh, validate-gate.sh, checkpoint)
#   AC6: Bats-core structural verification
#
# Usage:
#   bats tests/skills/gaia-a11y-testing.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  SKILL_DIR="$SKILLS_DIR/gaia-a11y-testing"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  SETUP_SCRIPT="$SKILL_DIR/scripts/setup.sh"
  FINALIZE_SCRIPT="$SKILL_DIR/scripts/finalize.sh"
}

# ---------- AC1: SKILL.md exists with valid frontmatter ----------

@test "AC1: SKILL.md exists at gaia-a11y-testing skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "AC1: SKILL.md has YAML frontmatter delimiters" {
  head -1 "$SKILL_FILE" | grep -q "^---$"
  awk 'NR>1 && /^---$/{found=1; exit} END{exit !found}' "$SKILL_FILE"
}

@test "AC1: SKILL.md frontmatter contains name: gaia-test-a11y (renamed from gaia-a11y-testing per E69-S1)" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^name: gaia-test-a11y"
}

@test "AC1: SKILL.md frontmatter contains description field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^description:"
}

@test "AC1: SKILL.md body contains WCAG compliance section" {
  grep -qi "wcag\|web content accessibility" "$SKILL_FILE"
}

@test "AC1: SKILL.md body contains automated checks section (axe-core or pa11y)" {
  grep -qi "axe-core\|pa11y\|automated.*check" "$SKILL_FILE"
}

@test "AC1: SKILL.md body contains keyboard navigation section" {
  grep -qi "keyboard.*nav\|keyboard.*test\|focus.*order" "$SKILL_FILE"
}

@test "AC1: SKILL.md body contains screen reader section" {
  grep -qi "screen.*reader\|voiceover\|nvda\|assistive.*tech" "$SKILL_FILE"
}

@test "AC1: SKILL.md body contains ARIA audit section" {
  grep -qi "aria\|landmark.*region\|aria-live" "$SKILL_FILE"
}

@test "AC1: SKILL.md body contains remediation priorities section" {
  grep -qi "remediation\|priorit" "$SKILL_FILE"
}

@test "AC1: SKILL.md references accessibility report output" {
  grep -q "accessibility-report\|test-artifacts" "$SKILL_FILE"
}

# ---------- AC5: Shared setup.sh/finalize.sh pattern ----------

@test "AC5: setup.sh exists and is executable" {
  [ -x "$SETUP_SCRIPT" ]
}

@test "AC5: finalize.sh exists and is executable" {
  [ -x "$FINALIZE_SCRIPT" ]
}

@test "AC5: setup.sh calls resolve-config.sh" {
  grep -q "resolve-config.sh" "$SETUP_SCRIPT"
}

@test "AC5: setup.sh calls validate-gate.sh" {
  grep -q "validate-gate.sh" "$SETUP_SCRIPT"
}

@test "AC5: setup.sh loads checkpoint" {
  grep -q "checkpoint" "$SETUP_SCRIPT"
}

@test "AC5: finalize.sh writes checkpoint" {
  grep -q "checkpoint" "$FINALIZE_SCRIPT"
}

@test "AC5: finalize.sh emits lifecycle event" {
  grep -q "lifecycle-event" "$FINALIZE_SCRIPT"
}

@test "AC5: SKILL.md invokes setup.sh at entry" {
  grep -q '!.*setup\.sh' "$SKILL_FILE"
}

@test "AC5: SKILL.md invokes finalize.sh at exit" {
  grep -q '!.*finalize\.sh' "$SKILL_FILE"
}

# ---------- AC6: Output format verification ----------

@test "AC6: SKILL.md references output to docs/test-artifacts/" {
  grep -q "docs/test-artifacts\|test-artifacts/" "$SKILL_FILE"
}

# ---------- Knowledge bundling (NFR-048) ----------

@test "NFR-048: knowledge directory contains wcag-checks.md" {
  [ -f "$SKILL_DIR/knowledge/wcag-checks.md" ]
}

@test "NFR-048: knowledge directory contains axe-core-patterns.md" {
  [ -f "$SKILL_DIR/knowledge/axe-core-patterns.md" ]
}

# ---------- E49-S1: WCAG-level explicit prompt + criterion mapping ----------

@test "E49-S1 AC1: SKILL.md prompts the user inline for WCAG level (no silent default)" {
  grep -q "Select WCAG level: A, AA, or AAA" "$SKILL_FILE"
}

@test "E49-S1 AC1: SKILL.md Critical Rules forbid silent WCAG default" {
  grep -q "WCAG level MUST be explicitly declared by the user" "$SKILL_FILE"
  ! grep -q "Default to WCAG 2.1 Level AA if not specified" "$SKILL_FILE"
  ! grep -q "Default to AA if unspecified" "$SKILL_FILE"
}

@test "E49-S1 AC1: SKILL.md documents YOLO auto-AA behaviour with audit log" {
  grep -q "YOLO: auto-selected WCAG 2.1 Level AA" "$SKILL_FILE"
}

@test "E49-S1 AC2: SKILL.md propagates WCAG level to wcag2a/wcag2aa/wcag2aaa rule sets" {
  grep -q "wcag2a" "$SKILL_FILE"
  grep -q "wcag2aa" "$SKILL_FILE"
  grep -q "wcag2aaa" "$SKILL_FILE"
}

@test "E49-S1 AC3: SKILL.md mandates >=1 remediation per Critical finding (hard rule)" {
  grep -q "every finding classified as Critical MUST include at least one specific remediation recommendation" "$SKILL_FILE"
}

@test "E49-S1 AC4: SKILL.md mandates X.Y.Z Criterion Name format on every finding" {
  grep -q "X.Y.Z Criterion Name" "$SKILL_FILE"
  grep -q "1.4.3 Contrast Minimum" "$SKILL_FILE"
}

@test "E49-S1 AC4: SKILL.md findings table schema includes WCAG Criterion column" {
  grep -q "WCAG Criterion" "$SKILL_FILE"
}

@test "E49-S1 AC5: SKILL.md requires automated checks to cover every Step 1 target" {
  grep -q "Automated test scenarios MUST cover every page and component identified in Step 1" "$SKILL_FILE"
}

@test "E49-S1: Step 6 enforces pre-write validation gate for criterion + critical remediation" {
  grep -q "Pre-write validation gate" "$SKILL_FILE"
}
