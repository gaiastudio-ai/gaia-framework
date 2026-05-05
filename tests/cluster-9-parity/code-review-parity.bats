#!/usr/bin/env bats
# code-review-parity.bats — E28-S66 parity + tool-allowlist enforcement tests
#
# Validates:
#   AC1: SKILL.md frontmatter matches brief's reference pattern (context:fork,
#        allowed-tools: Read Grep Glob Bash, NO Write, NO Edit)
#   AC3: Tool-allowlist enforcement — Write and Edit are absent from allowlist
#   AC4: Shared scaffolding (setup.sh + finalize.sh + review-gate.sh pattern)
#   AC5: Frontmatter linter conformance
#
# Refs: E28-S66, NFR-048, NFR-052, ADR-041, ADR-045
#
# Usage:
#   bats tests/cluster-9-parity/code-review-parity.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"

  SKILL="gaia-code-review"
  SKILL_DIR="$SKILLS_DIR/$SKILL"
}

# ---------- AC1: Frontmatter conformance ----------

@test "E28-S66: SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "E28-S66: SKILL.md frontmatter has name: gaia-review-code (renamed from gaia-code-review per E69-S1)" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q '^name: gaia-review-code$'
}

@test "E28-S66: SKILL.md frontmatter has context: fork" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q '^context: fork'
}

@test "E28-S66: SKILL.md frontmatter has allowed-tools containing Read" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Read'
}

@test "E28-S66: SKILL.md frontmatter has allowed-tools containing Grep" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Grep'
}

@test "E28-S66: SKILL.md frontmatter has allowed-tools containing Glob" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Glob'
}

@test "E28-S66: SKILL.md frontmatter has allowed-tools containing Bash" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Bash'
}

# ---------- AC3: Tool-allowlist enforcement (NFR-048) ----------

@test "E28-S66: SKILL.md allowed-tools does NOT contain Write" {
  local tools_line
  tools_line=$(head -20 "$SKILL_DIR/SKILL.md" | grep '^allowed-tools:')
  [[ "$tools_line" != *"Write"* ]]
}

@test "E28-S66: SKILL.md allowed-tools does NOT contain Edit" {
  local tools_line
  tools_line=$(head -20 "$SKILL_DIR/SKILL.md" | grep '^allowed-tools:')
  [[ "$tools_line" != *"Edit"* ]]
}

# ---------- AC4: Shared scaffolding ----------

@test "E28-S66: setup.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/setup.sh" ]
  [ -x "$SKILL_DIR/scripts/setup.sh" ]
}

@test "E28-S66: finalize.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/finalize.sh" ]
  [ -x "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "E28-S66: SKILL.md references setup.sh via bang-include" {
  grep -q '!.*setup\.sh' "$SKILL_DIR/SKILL.md"
}

@test "E28-S66: SKILL.md references finalize.sh via bang-include" {
  grep -q '!.*finalize\.sh' "$SKILL_DIR/SKILL.md"
}

@test "E28-S66: SKILL.md references review-gate.sh for verdict writing" {
  grep -q 'review-gate\.sh' "$SKILL_DIR/SKILL.md"
}

# ---------- AC5: _reference-frontmatter.md ----------

@test "E28-S66: _reference-frontmatter.md exists" {
  [ -f "$SKILL_DIR/_reference-frontmatter.md" ]
}

@test "E28-S66: _reference-frontmatter.md contains verbatim brief example" {
  grep -q 'name: gaia-code-review' "$SKILL_DIR/_reference-frontmatter.md"
  grep -q 'context: fork' "$SKILL_DIR/_reference-frontmatter.md"
  grep -q 'allowed-tools: Read Grep Glob Bash' "$SKILL_DIR/_reference-frontmatter.md"
}

# ---------- AC2: Verdict logic ----------

@test "E28-S66: SKILL.md contains APPROVE verdict logic" {
  grep -q 'APPROVE' "$SKILL_DIR/SKILL.md"
}

@test "E28-S66: SKILL.md contains REQUEST_CHANGES verdict logic" {
  grep -q 'REQUEST_CHANGES' "$SKILL_DIR/SKILL.md"
}

@test "E28-S66: SKILL.md maps APPROVE to PASSED for review-gate.sh" {
  grep -q 'PASSED' "$SKILL_DIR/SKILL.md"
}

@test "E28-S66: SKILL.md maps REQUEST_CHANGES to FAILED for review-gate.sh" {
  grep -q 'FAILED' "$SKILL_DIR/SKILL.md"
}

@test "E28-S66: SKILL.md has argument-hint for story-key" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'argument-hint:.*story-key'
}

# ---------- Shared scripts existence ----------

@test "E28-S66: review-gate.sh exists in shared scripts dir" {
  [ -f "$SCRIPTS_DIR/review-gate.sh" ]
}

@test "E28-S66: setup.sh references resolve-config.sh" {
  grep -q 'resolve-config\.sh' "$SKILL_DIR/scripts/setup.sh"
}

@test "E28-S66: finalize.sh references checkpoint.sh" {
  grep -q 'checkpoint\.sh' "$SKILL_DIR/scripts/finalize.sh"
}

@test "E28-S66: finalize.sh references lifecycle-event.sh" {
  grep -q 'lifecycle-event\.sh' "$SKILL_DIR/scripts/finalize.sh"
}
