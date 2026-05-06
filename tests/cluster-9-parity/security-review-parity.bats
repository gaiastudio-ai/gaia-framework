#!/usr/bin/env bats
# security-review-parity.bats — E28-S67 parity + tool-allowlist enforcement tests
#
# Validates:
#   AC1: SKILL.md frontmatter matches canonical reviewer pattern (context:fork,
#        allowed-tools: Read Grep Glob Bash, NO Write, NO Edit)
#   AC2: Subagent wiring — Zara dispatched for OWASP analysis
#   AC3: OWASP methodology preserved verbatim from legacy workflow
#   AC4: review-gate.sh integration with review_name = "Security Review"
#   AC5: Frontmatter linter conformance + cluster validation harness
#
# Refs: E28-S67, NFR-048, NFR-052, ADR-041, ADR-045
#
# Usage:
#   bats tests/cluster-9-parity/security-review-parity.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"

  SKILL="gaia-security-review"
  SKILL_DIR="$SKILLS_DIR/$SKILL"
}

# ---------- AC1: Frontmatter conformance ----------

@test "E28-S67: SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "E28-S67: SKILL.md frontmatter has name: deprecated-gaia-security-review (retired per E69-S1; canonical is gaia-review-security)" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q '^name: deprecated-gaia-security-review'
}

@test "E28-S67: SKILL.md frontmatter has context: fork" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q '^context: fork'
}

@test "E28-S67: SKILL.md frontmatter has allowed-tools containing Read" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Read'
}

@test "E28-S67: SKILL.md frontmatter has allowed-tools containing Grep" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Grep'
}

@test "E28-S67: SKILL.md frontmatter has allowed-tools containing Glob" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Glob'
}

@test "E28-S67: SKILL.md frontmatter has allowed-tools containing Bash" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Bash'
}

# ---------- AC1: Tool-allowlist enforcement (NFR-048) ----------

@test "E28-S67: SKILL.md allowed-tools does NOT contain Write" {
  local tools_line
  tools_line=$(head -20 "$SKILL_DIR/SKILL.md" | grep '^allowed-tools:')
  [[ "$tools_line" != *"Write"* ]]
}

@test "E28-S67: SKILL.md allowed-tools does NOT contain Edit" {
  local tools_line
  tools_line=$(head -20 "$SKILL_DIR/SKILL.md" | grep '^allowed-tools:')
  [[ "$tools_line" != *"Edit"* ]]
}

# ---------- AC2: Subagent wiring (Zara) ----------

@test "E28-S67: SKILL.md references Zara subagent" {
  grep -qi 'zara' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md dispatches OWASP analysis to subagent" {
  grep -q 'security' "$SKILL_DIR/SKILL.md"
}

# ---------- AC3: OWASP methodology verbatim ----------

@test "E28-S67: SKILL.md contains OWASP A01 Broken Access Control" {
  grep -q 'A01.*Broken Access Control' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains OWASP A02 Cryptographic Failures" {
  grep -q 'A02.*Cryptographic Failures' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains OWASP A03 Injection" {
  grep -q 'A03.*Injection' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains OWASP A04 Insecure Design" {
  grep -q 'A04.*Insecure Design' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains OWASP A05 Security Misconfiguration" {
  grep -q 'A05.*Security Misconfiguration' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains OWASP A06 Vulnerable Components" {
  grep -q 'A06.*Vulnerable Components' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains OWASP A07 Auth Failures" {
  grep -q 'A07.*Auth Failures' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains OWASP A08 Data Integrity Failures" {
  grep -q 'A08.*Data Integrity Failures' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains OWASP A09 Logging Failures" {
  grep -q 'A09.*Logging Failures' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains OWASP A10 SSRF" {
  grep -q 'A10.*SSRF' "$SKILL_DIR/SKILL.md"
}

# ---------- AC3: Data Privacy and Compliance (legacy step 5b) ----------

@test "E28-S67: SKILL.md contains Data Privacy and Compliance section" {
  grep -q 'Data Privacy' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md contains PII handling check" {
  grep -q 'PII' "$SKILL_DIR/SKILL.md"
}

# ---------- AC4: Shared scaffolding ----------

@test "E28-S67: setup.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/setup.sh" ]
  [ -x "$SKILL_DIR/scripts/setup.sh" ]
}

@test "E28-S67: finalize.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/finalize.sh" ]
  [ -x "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "E28-S67: SKILL.md references setup.sh via bang-include" {
  grep -q '!.*setup\.sh' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md references finalize.sh via bang-include" {
  grep -q '!.*finalize\.sh' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md references review-gate.sh for verdict writing" {
  grep -q 'review-gate\.sh' "$SKILL_DIR/SKILL.md"
}

# ---------- AC4: Review Gate vocabulary ----------

@test "E28-S67: SKILL.md verdict uses PASSED for Review Gate" {
  grep -q 'PASSED' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md verdict uses FAILED for Review Gate" {
  grep -q 'FAILED' "$SKILL_DIR/SKILL.md"
}

@test "E28-S67: SKILL.md calls review-gate.sh with Security Review gate name" {
  grep -q '"Security Review"' "$SKILL_DIR/SKILL.md"
}

# ---------- AC5: Frontmatter extras ----------

@test "E28-S67: SKILL.md has argument-hint for story-key" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'argument-hint:.*story-key'
}

@test "E28-S67: _reference-frontmatter.md exists" {
  [ -f "$SKILL_DIR/_reference-frontmatter.md" ]
}

@test "E28-S67: _reference-frontmatter.md contains verbatim brief example" {
  grep -q 'name: gaia-security-review' "$SKILL_DIR/_reference-frontmatter.md"
  grep -q 'context: fork' "$SKILL_DIR/_reference-frontmatter.md"
  grep -q 'allowed-tools: Read Grep Glob Bash' "$SKILL_DIR/_reference-frontmatter.md"
}

# ---------- Shared scripts existence ----------

@test "E28-S67: review-gate.sh exists in shared scripts dir" {
  [ -f "$SCRIPTS_DIR/review-gate.sh" ]
}

@test "E28-S67: setup.sh references resolve-config.sh" {
  grep -q 'resolve-config\.sh' "$SKILL_DIR/scripts/setup.sh"
}

@test "E28-S67: finalize.sh references checkpoint.sh" {
  grep -q 'checkpoint\.sh' "$SKILL_DIR/scripts/finalize.sh"
}

@test "E28-S67: finalize.sh references lifecycle-event.sh" {
  grep -q 'lifecycle-event\.sh' "$SKILL_DIR/scripts/finalize.sh"
}
