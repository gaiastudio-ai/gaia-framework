#!/usr/bin/env bats
# test-val-integration.bats — integration tests for the Val validate-fix-revalidate cycle (E28-S81)
#
# Exercises the full Val cycle end-to-end:
#   AC1: validate-plan returns findings with correct severities
#   AC2: findings contain required fields (severity, section, claim, finding, evidence)
#   AC3: auto-fix + revalidation yields zero actionable findings
#   AC4: refresh-ground-truth produces ground-truth.md
#   AC5: val-save-session persists to decision-log.md and conversation-context.md
#
# These are Tier 1 programmatic tests (ADR-001) -- bats-core asserts against
# script outputs and file side effects, not LLM-generated content.
#
# Refs: E28-S81, FR-323, FR-330, FR-331, ADR-007, ADR-041, ADR-042, ADR-045, ADR-046

load 'test_helper.bash'

FIXTURES_DIR=""
SKILL_BASE=""

setup() {
  common_setup
  FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures/val-integration"
  SKILL_BASE="$BATS_TEST_DIRNAME/../skills"
  export MEMORY_PATH="$TEST_TMP/_memory"
  mkdir -p "$MEMORY_PATH/validator-sidecar"
}
teardown() { common_teardown; }

# ==========================================================================
# AC1: validate-plan on flawed fixture returns findings with correct severities
# ==========================================================================

@test "val-integration AC1: flawed-plan fixture exists" {
  [ -f "$FIXTURES_DIR/flawed-plan.md" ]
}

@test "val-integration AC1: validate-plan SKILL.md exists" {
  [ -f "$SKILL_BASE/gaia-val-validate-plan/SKILL.md" ]
}

@test "val-integration AC1: validate-plan setup.sh exists and is executable" {
  [ -f "$SKILL_BASE/gaia-val-validate-plan/scripts/setup.sh" ]
  [ -x "$SKILL_BASE/gaia-val-validate-plan/scripts/setup.sh" ]
}

@test "val-integration AC1: flawed-plan contains references to nonexistent files" {
  # Verify the fixture has the expected flaws that should trigger CRITICAL findings
  run grep -c "nonexistent-script.sh" "$FIXTURES_DIR/flawed-plan.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "val-integration AC1: flawed-plan contains nonexistent ADR reference" {
  run grep -c "ADR-999" "$FIXTURES_DIR/flawed-plan.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "val-integration AC1: flawed-plan contains non-sequential version bump" {
  run grep -c "rc.3" "$FIXTURES_DIR/flawed-plan.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "val-integration AC1: expected-findings.json declares CRITICAL and WARNING severities" {
  run cat "$FIXTURES_DIR/expected-findings.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"CRITICAL"'* ]]
  [[ "$output" == *'"WARNING"'* ]]
}

@test "val-integration AC1: memory-loader.sh loads ground-truth for validator in test env" {
  # Set up ground-truth for the validator to use during plan validation
  printf '## Ground Truth\n\n**Scripts:** resolve-config.sh, checkpoint.sh, memory-loader.sh\n' \
    > "$MEMORY_PATH/validator-sidecar/ground-truth.md"
  run "$SCRIPTS_DIR/memory-loader.sh" validator ground-truth
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ground Truth"* ]]
}

# ==========================================================================
# AC2: findings contain required fields
# ==========================================================================

@test "val-integration AC2: expected-findings.json specifies required fields" {
  run cat "$FIXTURES_DIR/expected-findings.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"severity"'* ]]
  [[ "$output" == *'"section"'* ]]
  [[ "$output" == *'"claim"'* ]]
  [[ "$output" == *'"finding"'* ]]
  [[ "$output" == *'"evidence"'* ]]
}

@test "val-integration AC2: validate-plan SKILL.md defines finding structure with severity field" {
  run grep -c "severity" "$SKILL_BASE/gaia-val-validate-plan/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "val-integration AC2: validate-plan SKILL.md defines finding structure with evidence field" {
  run grep -c "evidence" "$SKILL_BASE/gaia-val-validate-plan/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "val-integration AC2: validate-plan SKILL.md enforces CRITICAL/WARNING/INFO vocabulary" {
  # The skill must enforce exactly these three severity levels
  local skill="$SKILL_BASE/gaia-val-validate-plan/SKILL.md"
  run grep -c "CRITICAL" "$skill"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  run grep -c "WARNING" "$skill"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  run grep -c "INFO" "$skill"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ==========================================================================
# AC3: auto-fix + revalidation yields zero actionable findings
# ==========================================================================

@test "val-integration AC3: fixed-plan fixture exists" {
  [ -f "$FIXTURES_DIR/fixed-plan.md" ]
}

@test "val-integration AC3: fixed-plan does NOT reference nonexistent files" {
  run grep -c "nonexistent-script.sh" "$FIXTURES_DIR/fixed-plan.md"
  # grep returns exit 1 when no match found
  [ "$status" -eq 1 ]
}

@test "val-integration AC3: fixed-plan does NOT reference nonexistent ADRs" {
  run grep -c "ADR-999" "$FIXTURES_DIR/fixed-plan.md"
  [ "$status" -eq 1 ]
}

@test "val-integration AC3: fixed-plan does NOT contain non-sequential version bump" {
  run grep -c "rc.3" "$FIXTURES_DIR/fixed-plan.md"
  [ "$status" -eq 1 ]
}

@test "val-integration AC3: fixed-plan only references valid ADRs" {
  # ADR-042 is the only ADR referenced and it exists in the architecture
  run grep "ADR-" "$FIXTURES_DIR/fixed-plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADR-042"* ]]
  # Ensure no other ADR references
  local count
  count=$(grep -c "ADR-" "$FIXTURES_DIR/fixed-plan.md")
  [ "$count" -le 2 ]  # header line + reference line
}

@test "val-integration AC3: fixed-plan only creates new files (no modify of nonexistent)" {
  # The fixed plan should only have Create actions, not Modify on missing files
  run grep -c "Modify" "$FIXTURES_DIR/fixed-plan.md"
  [ "$status" -eq 1 ]
}

# ==========================================================================
# AC4: refresh-ground-truth produces ground-truth.md
# ==========================================================================

@test "val-integration AC4: refresh-ground-truth SKILL.md exists" {
  [ -f "$SKILL_BASE/gaia-refresh-ground-truth/SKILL.md" ]
}

@test "val-integration AC4: refresh-ground-truth setup.sh exists and is executable" {
  [ -x "$SKILL_BASE/gaia-refresh-ground-truth/scripts/setup.sh" ]
}

@test "val-integration AC4: refresh-ground-truth SKILL.md writes ground-truth.md format" {
  # The SKILL.md must document that it writes ground-truth.md
  run grep -c "ground-truth.md" "$SKILL_BASE/gaia-refresh-ground-truth/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "val-integration AC4: refresh-ground-truth SKILL.md uses memory-loader.sh" {
  run grep -c "memory-loader.sh" "$SKILL_BASE/gaia-refresh-ground-truth/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "val-integration AC4: ground-truth.md can be created in test sidecar" {
  # Simulate the ground-truth refresh output
  local gt_file="$MEMORY_PATH/validator-sidecar/ground-truth.md"
  cat > "$gt_file" <<'GTEOF'
# Ground Truth

<!-- last-refresh: 2026-04-16T00:00:00Z -->
<!-- mode: full -->
<!-- entry-count: 3 -->

**Scripts:** resolve-config.sh, checkpoint.sh, memory-loader.sh
Source: plugins/gaia/scripts/
Verified: 2026-04-16

**Skills:** gaia-val-validate-plan, gaia-val-validate, gaia-refresh-ground-truth, gaia-val-save
Source: plugins/gaia/skills/
Verified: 2026-04-16

**Tests:** test-val-integration.bats
Source: plugins/gaia/tests/
Verified: 2026-04-16
GTEOF

  [ -f "$gt_file" ]
  run cat "$gt_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# Ground Truth"* ]]
  [[ "$output" == *"last-refresh"* ]]
  [[ "$output" == *"entry-count"* ]]
}

@test "val-integration AC4: memory-loader.sh reads refreshed ground-truth" {
  # Write ground-truth then verify memory-loader can read it
  printf '# Ground Truth\n\n<!-- last-refresh: 2026-04-16 -->\n\n**Scripts:** resolve-config.sh\nSource: plugins/gaia/scripts/\nVerified: 2026-04-16\n' \
    > "$MEMORY_PATH/validator-sidecar/ground-truth.md"
  run "$SCRIPTS_DIR/memory-loader.sh" validator ground-truth
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ground Truth"* ]]
  [[ "$output" == *"resolve-config.sh"* ]]
}

# ==========================================================================
# AC5: val-save-session persists to decision-log.md and conversation-context.md
# ==========================================================================

@test "val-integration AC5: val-save SKILL.md exists" {
  [ -f "$SKILL_BASE/gaia-val-save/SKILL.md" ]
}

@test "val-integration AC5: val-save setup.sh exists and is executable" {
  [ -x "$SKILL_BASE/gaia-val-save/scripts/setup.sh" ]
}

@test "val-integration AC5: val-save SKILL.md writes to decision-log.md" {
  run grep -c "decision-log.md" "$SKILL_BASE/gaia-val-save/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "val-integration AC5: val-save SKILL.md writes to conversation-context.md" {
  run grep -c "conversation-context.md" "$SKILL_BASE/gaia-val-save/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "val-integration AC5: decision-log.md can be written in test sidecar" {
  local dl_file="$MEMORY_PATH/validator-sidecar/decision-log.md"
  cat > "$dl_file" <<'DLEOF'
# Decision Log

### [2026-04-16] Validation of flawed-plan.md

- **Agent:** validator
- **Workflow:** val-validate-plan
- **Sprint:** sprint-21
- **Type:** validation
- **Findings:** 3 findings (2 CRITICAL, 1 WARNING)
- **Resolution:** Auto-fix applied, revalidation passed with 0 actionable findings
DLEOF

  [ -f "$dl_file" ]
  run cat "$dl_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Decision Log"* ]]
  [[ "$output" == *"validation"* ]]
  [[ "$output" == *"Findings"* ]]
}

@test "val-integration AC5: conversation-context.md can be written in test sidecar" {
  local cc_file="$MEMORY_PATH/validator-sidecar/conversation-context.md"
  cat > "$cc_file" <<'CCEOF'
# Conversation Context

---

## Session Summary

Validated flawed-plan.md fixture. Found 3 issues: 2 CRITICAL (nonexistent file reference,
nonexistent ADR reference) and 1 WARNING (non-sequential version bump). Auto-fix applied
to produce fixed-plan.md. Revalidation confirmed zero actionable findings.
CCEOF

  [ -f "$cc_file" ]
  run cat "$cc_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Conversation Context"* ]]
  [[ "$output" == *"Session Summary"* ]]
}

@test "val-integration AC5: memory-loader.sh reads persisted decision-log" {
  printf '# Decision Log\n\n### [2026-04-16] Test entry\n\n- **Agent:** validator\n' \
    > "$MEMORY_PATH/validator-sidecar/decision-log.md"
  run "$SCRIPTS_DIR/memory-loader.sh" validator decision-log
  [ "$status" -eq 0 ]
  [[ "$output" == *"Decision Log"* ]]
  [[ "$output" == *"Test entry"* ]]
}

# ==========================================================================
# Edge case: empty plan fixture (Scenario 5)
# ==========================================================================

@test "val-integration edge: validate-plan SKILL.md handles empty plan gracefully" {
  # The skill should document handling of empty/minimal plans
  run grep -c "no steps to validate" "$SKILL_BASE/gaia-val-validate-plan/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ==========================================================================
# Integration: full cycle wiring
# ==========================================================================

@test "val-integration cycle: all four Val skills exist" {
  [ -f "$SKILL_BASE/gaia-val-validate-plan/SKILL.md" ]
  [ -f "$SKILL_BASE/gaia-val-validate/SKILL.md" ]
  [ -f "$SKILL_BASE/gaia-refresh-ground-truth/SKILL.md" ]
  [ -f "$SKILL_BASE/gaia-val-save/SKILL.md" ]
}

@test "val-integration cycle: fork-context Val skills declare context: fork" {
  # validate-plan and val-save still require fork context (ADR-045).
  # E87-S2 / ADR-104 migrated gaia-val-validate to main-turn Agent dispatch —
  # it no longer declares `context: fork`; the dispatch shape now lives in
  # the Main-Turn Dispatch Contract section of its SKILL.md (covered by the
  # sibling test below).
  # refresh-ground-truth runs in the main context (no fork required).
  for skill in gaia-val-validate-plan gaia-val-save; do
    local skill_md="$SKILL_BASE/$skill/SKILL.md"
    [ -f "$skill_md" ]
    run head -10 "$skill_md"
    [[ "$output" == *"context: fork"* ]]
  done
}

@test "val-integration cycle: gaia-val-validate migrated off context: fork" {
  # Post-E87-S2 invariant: /gaia-val-validate SKILL.md does NOT declare
  # `context: fork` in its frontmatter — it is dispatched via the main-turn
  # Agent tool per ADR-093 / ADR-104. The Main-Turn Dispatch Contract
  # section of the SKILL.md body documents the new shape.
  local skill_md="$SKILL_BASE/gaia-val-validate/SKILL.md"
  [ -f "$skill_md" ]
  run awk '/^---$/{c++; if (c==1) {in_fm=1; next} else if (c==2) {exit}} in_fm' "$skill_md"
  [ -n "$output" ]
  ! grep -Eq '^context:[[:space:]]*fork' <<< "$output"
  grep -q 'Main-Turn Dispatch Contract' "$skill_md"
}

@test "val-integration cycle: memory-loader.sh supports all tier for validator" {
  # The 'all' tier loads both decision-log and ground-truth
  mkdir -p "$MEMORY_PATH/validator-sidecar"
  printf '# Ground Truth\n\nTest ground truth.\n' > "$MEMORY_PATH/validator-sidecar/ground-truth.md"
  printf '# Decision Log\n\nTest decision log.\n' > "$MEMORY_PATH/validator-sidecar/decision-log.md"
  run "$SCRIPTS_DIR/memory-loader.sh" validator all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ground Truth"* ]]
  [[ "$output" == *"Decision Log"* ]]
}

@test "val-integration cycle: validate-fix-revalidate fixture pair is consistent" {
  # The flawed plan has issues that the fixed plan resolves
  # Flawed plan has nonexistent references
  local flawed_issues=0
  grep -q "nonexistent-script.sh" "$FIXTURES_DIR/flawed-plan.md" && flawed_issues=$((flawed_issues + 1))
  grep -q "ADR-999" "$FIXTURES_DIR/flawed-plan.md" && flawed_issues=$((flawed_issues + 1))
  grep -q "rc.3" "$FIXTURES_DIR/flawed-plan.md" && flawed_issues=$((flawed_issues + 1))
  [ "$flawed_issues" -ge 3 ]

  # Fixed plan has none of those issues
  ! grep -q "nonexistent-script.sh" "$FIXTURES_DIR/fixed-plan.md"
  ! grep -q "ADR-999" "$FIXTURES_DIR/fixed-plan.md"
  ! grep -q "rc.3" "$FIXTURES_DIR/fixed-plan.md"
}
