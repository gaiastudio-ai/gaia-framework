#!/usr/bin/env bats
# test-design-parity.bats — E28-S82 parity + structure tests
#
# Validates:
#   AC1: SKILL.md frontmatter matches standard skill pattern (E28-S19)
#   AC2: test-plan-template.md bundled alongside SKILL.md and non-empty
#   AC3: Skill wired to Sable (test-architect subagent)
#   AC4: Legacy output preserved — risk assessment, test strategy, quality gates
#   AC5: bats-core test infrastructure validates skill structure
#   AC-EC1: _reference-frontmatter.md exists for linter
#   AC-EC2: Empty template guard documented in SKILL.md
#   AC-EC4: Missing architecture/PRD handling documented
#
# Refs: E28-S82, NFR-048, NFR-053, ADR-041, ADR-042, FR-323
#
# Usage:
#   bats tests/cluster-11-parity/test-design-parity.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"

  SKILL="gaia-test-design"
  SKILL_DIR="$SKILLS_DIR/$SKILL"
}

# ---------- AC1: Frontmatter conformance ----------

@test "E28-S82: SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "E28-S82: SKILL.md frontmatter has name: deprecated-gaia-test-design (retired E69-S3)" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q '^name: deprecated-gaia-test-design'
}

@test "E28-S82: SKILL.md frontmatter has description" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q '^description:'
}

@test "E28-S82: SKILL.md frontmatter has context: fork" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q '^context: fork'
}

@test "E28-S82: SKILL.md frontmatter has allowed-tools containing Read" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Read'
}

@test "E28-S82: SKILL.md frontmatter has allowed-tools containing Write" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Write'
}

@test "E28-S82: SKILL.md frontmatter has allowed-tools containing Agent" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Agent'
}

# ---------- AC2: Test plan template bundled ----------

@test "E28-S82: test-plan-template.md exists in skill directory" {
  [ -f "$SKILL_DIR/test-plan-template.md" ]
}

@test "E28-S82: test-plan-template.md is non-empty" {
  [ -s "$SKILL_DIR/test-plan-template.md" ]
}

@test "E28-S82: test-plan-template.md contains Risk Assessment section" {
  grep -q 'Risk Assessment' "$SKILL_DIR/test-plan-template.md"
}

@test "E28-S82: test-plan-template.md contains Quality Gates section" {
  grep -q 'Quality Gates' "$SKILL_DIR/test-plan-template.md"
}

@test "E28-S82: test-plan-template.md contains Test Pyramid section" {
  grep -qi 'Test Pyramid\|Unit Tests' "$SKILL_DIR/test-plan-template.md"
}

# ---------- AC3: Subagent dispatch to Sable ----------

@test "E28-S82: SKILL.md references Sable test-architect subagent" {
  grep -qi 'sable' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: SKILL.md references test-architect subagent path" {
  grep -q 'test-architect' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: SKILL.md delegates to architect subagent via Agent tool" {
  grep -qi 'agent.*test-architect\|subagent.*sable\|delegate.*sable' "$SKILL_DIR/SKILL.md"
}

# ---------- AC4: Legacy output preserved ----------

@test "E28-S82: SKILL.md contains risk assessment step" {
  grep -qi 'risk assessment' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: SKILL.md contains test strategy step" {
  grep -qi 'test strategy' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: SKILL.md contains quality gates step" {
  grep -qi 'quality gates' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: SKILL.md contains test pyramid reference" {
  grep -qi 'test pyramid' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: SKILL.md contains brownfield/legacy integration step" {
  grep -qi 'brownfield\|legacy.*integration.*boundaries' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: SKILL.md contains coverage targets reference" {
  grep -qi 'coverage.*target' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: SKILL.md outputs to test-plan.md" {
  grep -q 'test-plan\.md' "$SKILL_DIR/SKILL.md"
}

# ---------- AC5: Scaffolding ----------

@test "E28-S82: setup.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/setup.sh" ]
  [ -x "$SKILL_DIR/scripts/setup.sh" ]
}

@test "E28-S82: finalize.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/finalize.sh" ]
  [ -x "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "E28-S82: SKILL.md references setup.sh via bang-include" {
  grep -q '!.*setup\.sh' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: SKILL.md references finalize.sh via bang-include" {
  grep -q '!.*finalize\.sh' "$SKILL_DIR/SKILL.md"
}

@test "E28-S82: setup.sh references resolve-config.sh" {
  grep -q 'resolve-config\.sh' "$SKILL_DIR/scripts/setup.sh"
}

@test "E28-S82: finalize.sh references checkpoint.sh" {
  grep -q 'checkpoint\.sh' "$SKILL_DIR/scripts/finalize.sh"
}

@test "E28-S82: finalize.sh references lifecycle-event.sh" {
  grep -q 'lifecycle-event\.sh' "$SKILL_DIR/scripts/finalize.sh"
}

# ---------- Reference frontmatter ----------

@test "E28-S82: _reference-frontmatter.md exists" {
  [ -f "$SKILL_DIR/_reference-frontmatter.md" ]
}

@test "E28-S82: _reference-frontmatter.md contains verbatim frontmatter" {
  grep -q 'name: gaia-test-design' "$SKILL_DIR/_reference-frontmatter.md"
  grep -q 'context: fork' "$SKILL_DIR/_reference-frontmatter.md"
}

# ---------- AC-EC2: Empty template guard ----------

@test "E28-S82: SKILL.md documents empty template detection" {
  grep -qi 'empty.*template\|template.*empty\|0.*byte\|non-empty' "$SKILL_DIR/SKILL.md"
}

# ---------- AC-EC4: Missing architecture/PRD handling ----------

@test "E28-S82: SKILL.md handles missing architecture input" {
  grep -qi 'missing.*architecture\|architecture.*missing\|without.*architecture\|architecture.*not found\|generic.*risk' "$SKILL_DIR/SKILL.md"
}

# ---------- AC-EC3: Unavailable subagent handling ----------

@test "E28-S82: SKILL.md documents subagent unavailability handling" {
  grep -qi 'unavailable\|not available\|not registered\|subagent.*missing' "$SKILL_DIR/SKILL.md"
}
