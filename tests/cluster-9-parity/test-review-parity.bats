#!/usr/bin/env bats
# test-review-parity.bats — E28-S70 parity + tool-allowlist enforcement tests
#
# Validates:
#   AC1: SKILL.md frontmatter matches brief's reference pattern (context:fork,
#        allowed-tools: Read Grep Glob Bash, NO Write, NO Edit)
#   AC2: Subagent dispatch to Vera (QA) and Sable (Test Architect)
#   AC3: review-gate.sh integration for "Test Review" row
#   AC4: Shared scaffolding (setup.sh + finalize.sh + review-gate.sh pattern)
#   AC5: Frontmatter linter conformance
#
# Refs: E28-S70, NFR-048, NFR-052, ADR-041, ADR-045
#
# Usage:
#   bats tests/cluster-9-parity/test-review-parity.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"

  SKILL="gaia-test-review"
  SKILL_DIR="$SKILLS_DIR/$SKILL"
}

# ---------- AC1: Frontmatter conformance ----------

@test "E28-S70: SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "E28-S70: SKILL.md frontmatter has name: gaia-review-test (renamed from gaia-test-review per E69-S1)" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q '^name: gaia-review-test$'
}

@test "E28-S70: SKILL.md frontmatter has context: fork" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q '^context: fork'
}

@test "E28-S70: SKILL.md frontmatter has allowed-tools containing Read" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Read'
}

@test "E28-S70: SKILL.md frontmatter has allowed-tools containing Grep" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Grep'
}

@test "E28-S70: SKILL.md frontmatter has allowed-tools containing Glob" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Glob'
}

@test "E28-S70: SKILL.md frontmatter has allowed-tools containing Bash" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'allowed-tools:.*Bash'
}

# ---------- AC1: Tool-allowlist enforcement (NFR-048) ----------

@test "E28-S70: SKILL.md allowed-tools does NOT contain Write" {
  local tools_line
  tools_line=$(head -20 "$SKILL_DIR/SKILL.md" | grep '^allowed-tools:')
  [[ "$tools_line" != *"Write"* ]]
}

@test "E28-S70: SKILL.md allowed-tools does NOT contain Edit" {
  local tools_line
  tools_line=$(head -20 "$SKILL_DIR/SKILL.md" | grep '^allowed-tools:')
  [[ "$tools_line" != *"Edit"* ]]
}

# ---------- AC2: Subagent dispatch to Vera and Sable ----------

@test "E28-S70: SKILL.md references Vera QA subagent" {
  grep -qi 'vera' "$SKILL_DIR/SKILL.md"
}

@test "E28-S70: SKILL.md references Sable Test Architect subagent" {
  grep -qi 'sable' "$SKILL_DIR/SKILL.md"
}

@test "E28-S70: SKILL.md references QA subagent" {
  grep -qi 'qa.*subagent\|subagent.*qa' "$SKILL_DIR/SKILL.md"
}

@test "E28-S70: SKILL.md references Test Architect subagent" {
  grep -qi 'test architect.*subagent\|subagent.*test architect' "$SKILL_DIR/SKILL.md"
}

# ---------- AC3: review-gate.sh integration ----------

@test "E28-S70: SKILL.md references review-gate.sh for verdict writing" {
  grep -q 'review-gate\.sh' "$SKILL_DIR/SKILL.md"
}

@test "E28-S70: SKILL.md references Test Review gate name" {
  grep -q 'Test Review' "$SKILL_DIR/SKILL.md"
}

@test "E28-S70: SKILL.md uses PASSED verdict vocabulary" {
  grep -q 'PASSED' "$SKILL_DIR/SKILL.md"
}

@test "E28-S70: SKILL.md uses FAILED verdict vocabulary" {
  grep -q 'FAILED' "$SKILL_DIR/SKILL.md"
}

@test "E28-S70: review-gate.sh accepts Test Review as a valid gate name" {
  # Seed a temporary story file with Review Gate table
  TEST_TMP="$(mktemp -d)"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts/stories"
  mkdir -p "$ART"
  cat > "$ART/RG70-fake.md" <<'STORY'
---
key: "RG70"
---

# Story: Fake

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
STORY
  run "$SCRIPTS_DIR/review-gate.sh" update --story RG70 --gate "Test Review" --verdict PASSED
  [ "$status" -eq 0 ]
  grep -q 'Test Review | PASSED' "$ART/RG70-fake.md"
  rm -rf "$TEST_TMP"
}

@test "E28-S70: review-gate.sh FAILED writes Test Review row" {
  TEST_TMP="$(mktemp -d)"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts/stories"
  mkdir -p "$ART"
  cat > "$ART/RG70F-fake.md" <<'STORY'
---
key: "RG70F"
---

# Story: Fake

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
STORY
  run "$SCRIPTS_DIR/review-gate.sh" update --story RG70F --gate "Test Review" --verdict FAILED
  [ "$status" -eq 0 ]
  grep -q 'Test Review | FAILED' "$ART/RG70F-fake.md"
  rm -rf "$TEST_TMP"
}

@test "E28-S70: review-gate.sh idempotent re-run does not duplicate rows" {
  TEST_TMP="$(mktemp -d)"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts/stories"
  mkdir -p "$ART"
  cat > "$ART/RG70I-fake.md" <<'STORY'
---
key: "RG70I"
---

# Story: Fake

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
STORY
  # Write PASSED twice
  "$SCRIPTS_DIR/review-gate.sh" update --story RG70I --gate "Test Review" --verdict PASSED
  "$SCRIPTS_DIR/review-gate.sh" update --story RG70I --gate "Test Review" --verdict PASSED
  # Count occurrences of Test Review — should be exactly 1
  local count
  count=$(grep -c 'Test Review' "$ART/RG70I-fake.md")
  [ "$count" -eq 1 ]
  rm -rf "$TEST_TMP"
}

# ---------- AC4: Shared scaffolding ----------

@test "E28-S70: setup.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/setup.sh" ]
  [ -x "$SKILL_DIR/scripts/setup.sh" ]
}

@test "E28-S70: finalize.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/finalize.sh" ]
  [ -x "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "E28-S70: SKILL.md references setup.sh via bang-include" {
  grep -q '!.*setup\.sh' "$SKILL_DIR/SKILL.md"
}

@test "E28-S70: SKILL.md references finalize.sh via bang-include" {
  grep -q '!.*finalize\.sh' "$SKILL_DIR/SKILL.md"
}

# ---------- AC5: _reference-frontmatter.md ----------

@test "E28-S70: _reference-frontmatter.md exists" {
  [ -f "$SKILL_DIR/_reference-frontmatter.md" ]
}

@test "E28-S70: _reference-frontmatter.md contains verbatim brief example" {
  grep -q 'name: gaia-test-review' "$SKILL_DIR/_reference-frontmatter.md"
  grep -q 'context: fork' "$SKILL_DIR/_reference-frontmatter.md"
  grep -q 'allowed-tools: Read Grep Glob Bash' "$SKILL_DIR/_reference-frontmatter.md"
}

@test "E28-S70: SKILL.md has argument-hint for story-key" {
  head -20 "$SKILL_DIR/SKILL.md" | grep -q 'argument-hint:.*story-key'
}

# ---------- Shared scripts existence ----------

@test "E28-S70: review-gate.sh exists in shared scripts dir" {
  [ -f "$SCRIPTS_DIR/review-gate.sh" ]
}

@test "E28-S70: setup.sh references resolve-config.sh" {
  grep -q 'resolve-config\.sh' "$SKILL_DIR/scripts/setup.sh"
}

@test "E28-S70: finalize.sh references checkpoint.sh" {
  grep -q 'checkpoint\.sh' "$SKILL_DIR/scripts/finalize.sh"
}

@test "E28-S70: finalize.sh references lifecycle-event.sh" {
  grep -q 'lifecycle-event\.sh' "$SKILL_DIR/scripts/finalize.sh"
}
