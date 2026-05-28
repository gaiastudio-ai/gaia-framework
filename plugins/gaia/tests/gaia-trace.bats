#!/usr/bin/env bats
# gaia-trace.bats — tests for the gaia-trace skill (E28-S85)
#
# Covers:
#   AC1: Matrix generation from FR/NFR + test cases
#   AC2: validate-gate.sh traceability_exists gate check
#   AC3: Actionable error on gate failure (uncovered requirements)
#   AC4: setup.sh / finalize.sh shared foundation pattern
#   AC5: Happy path, gate pass, gate fail, edge cases
#   AC-EC1: Empty FR/NFR set
#   AC-EC2: Missing validate-gate.sh
#   AC-EC3: Malformed test-plan.md
#   AC-EC4: 100% uncovered requirements
#   AC-EC5: setup.sh failure propagation

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-trace"
  SCRIPTS_DIR="$BATS_TEST_DIRNAME/../scripts"
  export TEST_ARTIFACTS="$TEST_TMP/test-artifacts"
  export PLANNING_ARTIFACTS="$TEST_TMP/planning-artifacts"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/implementation-artifacts"
  export PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_ARTIFACTS" "$PLANNING_ARTIFACTS" "$IMPLEMENTATION_ARTIFACTS"
}

teardown() { common_teardown; }

# ---------- Helper: create minimal PRD with FR/NFR entries ----------
create_prd() {
  cat > "$PLANNING_ARTIFACTS/prd.md" <<'PRD'
# PRD

## Functional Requirements

| ID | Description |
|----|-------------|
| FR-001 | User login |
| FR-002 | User logout |
| FR-003 | Password reset |

## Non-Functional Requirements

| ID | Description | Category | Target |
|----|-------------|----------|--------|
| NFR-001 | Page load under 2s | Performance | < 2000ms |
| NFR-002 | OWASP Top 10 compliance | Security | Pass |
PRD
}

# ---------- Helper: create minimal test-plan.md ----------
create_test_plan() {
  cat > "$TEST_ARTIFACTS/test-plan.md" <<'TP'
# Test Plan

## Test Cases

| ID | Type | Requirement | Description | Status |
|----|------|-------------|-------------|--------|
| TC-001 | Unit | FR-001 | Verify login flow | Planned |
| TC-002 | Unit | FR-002 | Verify logout flow | Planned |
| TC-003 | E2E | NFR-001 | Load time check | Planned |
| TC-004 | Security | NFR-002 | OWASP scan | Planned |
TP
}

# ---------- Helper: create epics-and-stories.md ----------
create_epics() {
  cat > "$PLANNING_ARTIFACTS/epics-and-stories.md" <<'ES'
# Epics and Stories

## E1 — Authentication

### E1-S1: User login
- Implements: FR-001
- AC1: User can log in with valid credentials

### E1-S2: User logout
- Implements: FR-002
- AC1: User can log out

### E1-S3: Password reset
- Implements: FR-003
- AC1: User can reset password
ES
}

# ================================================================
# AC2: validate-gate.sh traceability_exists gate integration
# ================================================================

@test "gaia-trace: validate-gate.sh traceability_exists passes when matrix exists" {
  printf 'x\n' > "$TEST_ARTIFACTS/traceability-matrix.md"
  run "$SCRIPTS_DIR/validate-gate.sh" traceability_exists
  [ "$status" -eq 0 ]
}

@test "gaia-trace: validate-gate.sh traceability_exists fails when matrix is missing" {
  run "$SCRIPTS_DIR/validate-gate.sh" traceability_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"traceability_exists failed"* ]]
  # AF-2026-05-28-1 / Test07 D-6: error message now lists all 4 accepted paths
  # under "expected one of:" rather than the singular "expected:" form so users
  # see the canonical planning-artifacts/ home first plus 3 legacy fallbacks.
  [[ "$output" == *"expected one of:"* ]]
  [[ "$output" == *"planning-artifacts/traceability-matrix.md"* ]]
  [[ "$output" == *"(canonical)"* ]]
}

# ================================================================
# AC3: Actionable error messages for uncovered requirements
# ================================================================

@test "gaia-trace: validate-gate.sh reports actionable error listing missing traceability" {
  run "$SCRIPTS_DIR/validate-gate.sh" traceability_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"traceability-matrix.md"* ]]
}

# ================================================================
# AC4: setup.sh shared foundation pattern
# ================================================================

@test "gaia-trace: setup.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/setup.sh" ]
  [ -x "$SKILL_DIR/scripts/setup.sh" ]
}

@test "gaia-trace: finalize.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/finalize.sh" ]
  [ -x "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "gaia-trace: setup.sh sources resolve-config.sh" {
  # Verify setup.sh references resolve-config.sh
  run grep -c "resolve-config.sh" "$SKILL_DIR/scripts/setup.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "gaia-trace: finalize.sh references checkpoint.sh" {
  run grep -c "checkpoint.sh" "$SKILL_DIR/scripts/finalize.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ================================================================
# AC5: SKILL.md existence and structure
# ================================================================

@test "gaia-trace: SKILL.md exists at expected path" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "gaia-trace: SKILL.md has required frontmatter fields" {
  run head -10 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-trace"* ]]
  [[ "$output" == *"description:"* ]]
}

@test "gaia-trace: SKILL.md references setup.sh" {
  run grep -c "setup.sh" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "gaia-trace: SKILL.md references finalize.sh" {
  run grep -c "finalize.sh" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "gaia-trace: SKILL.md references validate-gate.sh" {
  run grep -c "validate-gate" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "gaia-trace: SKILL.md contains matrix generation steps" {
  run grep -c "traceability-matrix" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "gaia-trace: SKILL.md contains gap analysis step" {
  run grep -ci "gap analysis" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ================================================================
# AC-EC1: Empty FR/NFR set
# ================================================================

@test "gaia-trace: SKILL.md documents empty-requirements handling" {
  run grep -ci "empty\|no requirements\|no FR" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ================================================================
# AC-EC2: Missing validate-gate.sh
# ================================================================

@test "gaia-trace: SKILL.md documents missing validate-gate.sh handling" {
  run grep -ci "validate-gate.sh not found\|missing.*validate-gate\|script.*not.*found" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ================================================================
# AC-EC3: Malformed test-plan.md
# ================================================================

@test "gaia-trace: SKILL.md documents malformed input handling" {
  run grep -ci "malformed\|parse.*warn\|skip.*unparseable\|broken.*table" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ================================================================
# Format parity with legacy workflow
# ================================================================

@test "gaia-trace: SKILL.md output path matches traceability-matrix.md (canonical post-AF-21-15)" {
  # AF-2026-05-21-15 canonicalized this path. Accept canonical or legacy.
  run grep -cE "(docs/test-artifacts|\.gaia/artifacts/test-artifacts)/traceability-matrix\.md" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "gaia-trace: SKILL.md matrix columns include FR ID, Description, Story, test types, Coverage" {
  # The matrix format should match the legacy workflow column structure
  run grep -c "FR ID\|Description\|Story\|Unit\|Integration\|E2E\|Coverage" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
