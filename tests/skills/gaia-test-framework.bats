#!/usr/bin/env bats
# gaia-test-framework.bats — test-framework skill structural tests (E28-S87)
#
# Validates:
#   AC1: SKILL.md exists with valid YAML frontmatter and expected sections
#   AC3: setup.sh calls resolve-config.sh, validate-gate.sh; finalize.sh writes checkpoint + lifecycle event
#   AC4: Bats-core structural verification
#
# Usage:
#   bats tests/skills/gaia-test-framework.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  SKILL_DIR="$SKILLS_DIR/gaia-test-framework"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  SETUP_SCRIPT="$SKILL_DIR/scripts/setup.sh"
  FINALIZE_SCRIPT="$SKILL_DIR/scripts/finalize.sh"
}

# ---------- AC1: SKILL.md exists with valid frontmatter ----------

@test "AC1: SKILL.md exists at gaia-test-framework skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "AC1: SKILL.md has YAML frontmatter delimiters" {
  head -1 "$SKILL_FILE" | grep -q "^---$"
  awk 'NR>1 && /^---$/{found=1; exit} END{exit !found}' "$SKILL_FILE"
}

@test "AC1: SKILL.md frontmatter contains name: deprecated-gaia-test-framework (retired E69-S3)" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^name: deprecated-gaia-test-framework"
}

@test "AC1: SKILL.md frontmatter contains description field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^description:"
}

@test "AC1: SKILL.md body contains stack detection section" {
  grep -qi "detect.*stack\|stack.*detect\|identify.*project.*language\|project.*stack" "$SKILL_FILE"
}

@test "AC1: SKILL.md body contains framework selection section" {
  grep -qi "vitest\|jest\|pytest\|junit\|playwright\|cypress" "$SKILL_FILE"
}

@test "AC1: SKILL.md body contains scaffold section" {
  grep -qi "scaffold\|config.*file\|folder.*structure\|test.*runner" "$SKILL_FILE"
}

@test "AC1: SKILL.md body contains fixture architecture section" {
  grep -qi "fixture\|factory.*pattern\|pure.*function" "$SKILL_FILE"
}

@test "AC1: SKILL.md references test-framework-setup.md output" {
  grep -q "test-framework-setup.md\|test-artifacts" "$SKILL_FILE"
}

# ---------- AC3: Shared setup.sh/finalize.sh pattern ----------

@test "AC3: setup.sh exists and is executable" {
  [ -x "$SETUP_SCRIPT" ]
}

@test "AC3: finalize.sh exists and is executable" {
  [ -x "$FINALIZE_SCRIPT" ]
}

@test "AC3: setup.sh calls resolve-config.sh" {
  grep -q "resolve-config.sh" "$SETUP_SCRIPT"
}

@test "AC3: setup.sh calls validate-gate.sh" {
  grep -q "validate-gate.sh" "$SETUP_SCRIPT"
}

@test "AC3: setup.sh loads checkpoint" {
  grep -q "checkpoint" "$SETUP_SCRIPT"
}

@test "AC3: finalize.sh writes checkpoint" {
  grep -q "checkpoint" "$FINALIZE_SCRIPT"
}

@test "AC3: finalize.sh emits lifecycle event" {
  grep -q "lifecycle-event" "$FINALIZE_SCRIPT"
}

@test "AC3: SKILL.md invokes setup.sh at entry" {
  grep -q '!.*setup\.sh' "$SKILL_FILE"
}

@test "AC3: SKILL.md invokes finalize.sh at exit" {
  grep -q '!.*finalize\.sh' "$SKILL_FILE"
}

# ---------- AC4: Output format verification ----------

@test "AC4: SKILL.md references output to docs/test-artifacts/" {
  grep -q "docs/test-artifacts\|test-artifacts/" "$SKILL_FILE"
}
