#!/usr/bin/env bats
# gaia-nfr.bats — nfr-assessment skill structural tests (E28-S88)
#
# Validates:
#   AC3: SKILL.md exists with valid YAML frontmatter and NFR assessment content
#   AC5: setup.sh/finalize.sh follow shared pattern
#   AC6: Bats-core structural verification
#
# Usage:
#   bats tests/skills/gaia-nfr.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  SKILL_DIR="$SKILLS_DIR/gaia-nfr"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  SETUP_SCRIPT="$SKILL_DIR/scripts/setup.sh"
  FINALIZE_SCRIPT="$SKILL_DIR/scripts/finalize.sh"
}

# ---------- AC3: SKILL.md exists with valid frontmatter ----------

@test "AC3: SKILL.md exists at gaia-nfr skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "AC3: SKILL.md has YAML frontmatter delimiters" {
  head -1 "$SKILL_FILE" | grep -q "^---$"
  awk 'NR>1 && /^---$/{found=1; exit} END{exit !found}' "$SKILL_FILE"
}

@test "AC3: SKILL.md frontmatter contains name: gaia-nfr" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^name: gaia-nfr"
}

@test "AC3: SKILL.md frontmatter contains description field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^description:"
}

@test "AC3: SKILL.md body contains performance assessment section" {
  grep -qi "performance.*assess\|response.*time\|throughput\|latency" "$SKILL_FILE"
}

@test "AC3: SKILL.md body contains security assessment section" {
  grep -qi "security.*assess\|authentication\|authorization\|data.*protection" "$SKILL_FILE"
}

@test "AC3: SKILL.md body contains reliability assessment section" {
  grep -qi "reliability.*assess\|availability\|fault.*tolerance\|recovery" "$SKILL_FILE"
}

@test "AC3: SKILL.md body contains scalability assessment section" {
  grep -qi "scalab\|capacity\|horizontal.*scal\|vertical.*scal" "$SKILL_FILE"
}

@test "AC3: SKILL.md body contains risk rating section" {
  grep -qi "risk.*rat\|high.*medium.*low\|risk.*level" "$SKILL_FILE"
}

@test "AC3: SKILL.md references NFR assessment output" {
  grep -q "nfr-assessment\|test-artifacts\|planning-artifacts" "$SKILL_FILE"
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
  grep -q "planning-artifacts/nfr-assessment\|test-artifacts/\|docs/test-artifacts" "$SKILL_FILE"  # E105-S3 / ADR-127 Pillar 3: nfr-assessment moved to planning-artifacts/ (legacy test-artifacts/ read-only)
}
