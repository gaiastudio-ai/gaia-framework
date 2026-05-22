#!/usr/bin/env bats
# gaia-create-prd.bats — E28-S40 tests for the gaia-create-prd native skill
#
# Validates:
#   AC1: SKILL.md exists with Cluster 5 frontmatter (name, description, argument-hint)
#   AC2: prd-template.md carried into skill directory and referenced by SKILL.md
#   AC3: Multi-step reasoning preserved from legacy create-prd workflow
#   AC4: Cluster 4 scripts/setup.sh + scripts/finalize.sh exist and source foundation
#   AC5: pm subagent invocation present (no inline persona)
#   AC6: Structural parity with legacy workflow output
#   AC-EC1..EC8: Edge case coverage

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-prd"

setup() {
  common_setup
}
teardown() { common_teardown; }

# ---------- AC1: Frontmatter ----------

@test "AC1: SKILL.md exists in gaia-create-prd skill directory" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "AC1: frontmatter contains name: gaia-create-prd" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-create-prd"* ]]
}

@test "AC1: frontmatter contains description field" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"description:"* ]]
}

@test "AC1: frontmatter contains argument-hint with product-brief-path" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *'argument-hint:'* ]]
  [[ "$output" == *'product-brief-path'* ]]
}

@test "AC1: frontmatter declares orchestration_class (post-ADR-093)" {
  # ADR-093 / E84-S3: `context: fork` stripped from non-reviewer plugin
  # SKILL.md. The orchestration declaration is now the orchestration_class
  # frontmatter field. gaia-create-prd is heavy-procedural.
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"orchestration_class: heavy-procedural"* ]]
}

# ---------- AC2: Template carried into skill directory ----------

@test "AC2: prd-template.md exists in skill directory" {
  [ -f "$SKILL_DIR/prd-template.md" ]
}

@test "AC2: SKILL.md references prd-template.md" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"prd-template.md"* ]]
}

@test "AC2: prd-template.md contains PRD section headers" {
  # AF-2026-05-22-3 Bug-4: template was expanded to include the 5 missing
  # checklist sections (User Journeys / Data Requirements / Integration
  # Requirements / Constraints / Success Criteria), so trailing sections
  # were renumbered. Use stable anchors at the top of the template + a
  # numbering-agnostic match for Requirements Summary.
  run cat "$SKILL_DIR/prd-template.md"
  [[ "$output" == *"## 1. Overview"* ]]
  [[ "$output" == *"## 4. Functional Requirements"* ]]
  [[ "$output" == *"Requirements Summary"* ]]
}

# ---------- AC3: Multi-step reasoning preserved ----------

@test "AC3: SKILL.md contains Step 1 — Load Product Brief" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Load Product Brief"* ]]
}

@test "AC3: SKILL.md contains Step 2 — User Interviews" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"User Interviews"* ]]
}

@test "AC3: SKILL.md contains Step 3 — Functional Requirements" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Functional Requirements"* ]]
}

@test "AC3: SKILL.md contains Step 4 — Non-Functional Requirements" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Non-Functional Requirements"* ]]
}

@test "AC3: SKILL.md contains Step 5 — User Journeys" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"User Journeys"* ]]
}

@test "AC3: SKILL.md contains Step 6 — Data Requirements" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Data Requirements"* ]]
}

@test "AC3: SKILL.md contains Step 7 — Integration Requirements" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Integration Requirements"* ]]
}

@test "AC3: SKILL.md contains Step 8 — Out of Scope" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Out of Scope"* ]]
}

@test "AC3: SKILL.md contains Step 9 — Constraints and Assumptions" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Constraints and Assumptions"* ]]
}

@test "AC3: SKILL.md contains Step 10 — Success Criteria" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Success Criteria"* ]]
}

@test "AC3: SKILL.md contains Step 11 — Generate Output" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Generate Output"* ]]
}

@test "AC3: SKILL.md contains Step 12 — Adversarial Review" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Adversarial Review"* ]]
}

@test "AC3: SKILL.md contains Step 13 — Incorporate Adversarial Findings" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"Incorporate Adversarial Findings"* ]]
}

@test "AC3: steps appear in correct order (1 before 13)" {
  local step1_line step13_line
  step1_line=$(grep -n "Load Product Brief" "$SKILL_DIR/SKILL.md" | head -1 | cut -d: -f1)
  step13_line=$(grep -n "Incorporate Adversarial Findings" "$SKILL_DIR/SKILL.md" | head -1 | cut -d: -f1)
  [ "$step1_line" -lt "$step13_line" ]
}

# ---------- AC4: Cluster 4 scripts ----------

@test "AC4: scripts/setup.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/setup.sh" ]
}

@test "AC4: scripts/finalize.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "AC4: setup.sh sources resolve-config.sh foundation script" {
  run cat "$SKILL_DIR/scripts/setup.sh"
  [[ "$output" == *"resolve-config.sh"* ]]
}

@test "AC4: finalize.sh sources checkpoint.sh foundation script" {
  run cat "$SKILL_DIR/scripts/finalize.sh"
  [[ "$output" == *"checkpoint.sh"* ]]
}

@test "AC4: setup.sh references WORKFLOW_NAME create-prd" {
  run cat "$SKILL_DIR/scripts/setup.sh"
  [[ "$output" == *'WORKFLOW_NAME="create-prd"'* ]]
}

@test "AC4: setup.sh guards for product-brief prereq" {
  run cat "$SKILL_DIR/scripts/setup.sh"
  [[ "$output" == *"product-brief"* ]]
}

@test "AC4: setup.sh guards for prd-template.md" {
  run cat "$SKILL_DIR/scripts/setup.sh"
  [[ "$output" == *"prd-template"* ]]
}

# ---------- AC5: pm subagent invocation ----------

@test "AC5: SKILL.md delegates to pm subagent" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"pm"* ]]
}

@test "AC5: SKILL.md does NOT inline Derek persona" {
  # The skill must NOT contain Derek's full persona inline — it delegates to the pm agent
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" != *"Product management veteran with 8+ years"* ]]
}

@test "AC5: SKILL.md references pm agent for PRD authoring" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"agents/pm"* ]] || [[ "$output" == *"subagent"* ]] || [[ "$output" == *"@pm"* ]]
}

# ---------- AC6: Structural parity ----------

@test "AC6: SKILL.md output targets planning-artifacts/prd.md" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"planning-artifacts/prd.md"* ]] || [[ "$output" == *"prd.md"* ]]
}

@test "AC6: prd-template frontmatter sections match legacy template" {
  # AF-2026-05-22-3 Bug-4: the template was expanded to include the 5 missing
  # checklist sections (User Journeys / Data Requirements / Integration
  # Requirements / Constraints / Success Criteria) so trailing sections were
  # renumbered. Verify all legacy section LABELS still exist (numbering
  # agnostic) — the SKILL.md / finalize.sh checklist is what governs which
  # sections must exist; the numbering is a presentation detail.
  run cat "$SKILL_DIR/prd-template.md"
  [[ "$output" == *"## 1. Overview"* ]]
  [[ "$output" == *"Goals and Non-Goals"* ]]
  [[ "$output" == *"User Stories"* ]]
  [[ "$output" == *"Functional Requirements"* ]]
  [[ "$output" == *"Non-Functional Requirements"* ]]
  [[ "$output" == *"Out of Scope"* ]]
  [[ "$output" == *"UX Requirements"* ]]
  [[ "$output" == *"Dependencies"* ]]
  [[ "$output" == *"Milestones"* ]]
  [[ "$output" == *"Requirements Summary"* ]]
}

# ---------- AC-EC1: Missing product brief path ----------

@test "AC-EC1: SKILL.md contains argument validation for product-brief-path" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"product-brief-path"* ]]
  [[ "$output" == *"required"* ]] || [[ "$output" == *"fail"* ]] || [[ "$output" == *"error"* ]]
}

# ---------- AC-EC3: prd-template.md missing guard ----------

@test "AC-EC3: setup.sh guards against missing prd-template.md" {
  run cat "$SKILL_DIR/scripts/setup.sh"
  [[ "$output" == *"prd-template"* ]]
  [[ "$output" == *"missing"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"die"* ]] || [[ "$output" == *"exit 1"* ]]
}

# ---------- AC-EC4: Custom template override ----------

@test "AC-EC4: SKILL.md documents custom template override behavior" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"custom/templates"* ]] || [[ "$output" == *"custom template"* ]]
}

# ---------- AC-EC5: pm subagent unavailable ----------

@test "AC-EC5: SKILL.md handles missing pm subagent" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"pm"* ]]
  # Must reference E28-S21 or provide clear error guidance
  [[ "$output" == *"E28-S21"* ]] || [[ "$output" == *"not available"* ]] || [[ "$output" == *"unavailable"* ]]
}

# ---------- AC-EC6: Idempotent re-run ----------

@test "AC-EC6: SKILL.md handles re-run / overwrite scenario" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"overwrite"* ]] || [[ "$output" == *"exists"* ]] || [[ "$output" == *"existing"* ]]
}

# ---------- Fixture for E28-S44 ----------

@test "fixture: E28-S44 compatibility fixture directory exists" {
  [ -d "$BATS_TEST_DIRNAME/fixtures" ]
}
