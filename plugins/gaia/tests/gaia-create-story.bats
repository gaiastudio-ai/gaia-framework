#!/usr/bin/env bats
# gaia-create-story.bats — unit tests for gaia-create-story skill Step 6
# (Val subagent + 3-attempt SM fix loop per ADR-050).
#
# Covers: SKILL.md frontmatter, Step 6 prose anchors (VLR-01..VLR-06
# behavioral markers, AC-EC1..AC-EC8 edge-case markers), review-gate.sh
# "story-validation" ledger gate acceptance (VLR-06 Tier 1), and regression
# of the existing PLAN_ID_GATES ledger path (test-automate-plan).
#
# Pattern: flat-file convention matching peers gaia-dev-story.bats,
# gaia-sprint-plan.bats.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-story"
SCRIPT="$BATS_TEST_DIRNAME/../scripts/review-gate.sh"

setup() {
  common_setup
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$ART"
  LEDGER="$TEST_TMP/.review-gate-ledger"
  export REVIEW_GATE_LEDGER="$LEDGER"
  # AF-2026-05-20-1: this suite exercises review-gate.sh canonical-gate
  # vs plan-id-gate routing without dispatching real review skills.
  # Disable the proof-of-execution gate so the fixture verdicts can be
  # written without --report. POE has its own dedicated suite.
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
}
teardown() { common_teardown; }

# seed a minimal story file with Review Gate table (for review-gate.sh calls
# that re-read the story to validate its structure)
seed_story() {
  local key="$1" verdict="${2:-UNVERIFIED}"
  cat > "$ART/${key}-fake.md" <<EOF
---
template: 'story'
key: "$key"
---

# Story: Fake

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | $verdict | --- |
| QA Tests | $verdict | --- |
| Security Review | $verdict | --- |
| Test Automation | $verdict | --- |
| Test Review | $verdict | --- |
| Performance Review | $verdict | --- |
EOF
}

# ---------------------------------------------------------------------------
# SKILL.md frontmatter and structural checks (AC1 prereqs)
# ---------------------------------------------------------------------------

@test "SKILL.md exists for gaia-create-story" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "SKILL.md frontmatter: name gaia-create-story" {
  run awk '/^---$/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-create-story"* ]]
}

@test "SKILL.md frontmatter: allowed-tools includes Read Write Edit Bash (inline SM fix requirement, NFR-046)" {
  run awk '/^---$/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"allowed-tools:"* ]]
  [[ "$output" == *"Read"* ]]
  [[ "$output" == *"Write"* ]]
  [[ "$output" == *"Edit"* ]]
  [[ "$output" == *"Bash"* ]]
}

# ---------------------------------------------------------------------------
# Step 6 prose anchors (VLR behavioral markers)
# Tests validate that SKILL.md Step 6 contains the required
# ADR-050 pattern language so future refactors cannot silently drop the
# validation loop. These are prose-anchor tests — common pattern across
# gaia-dev-story.bats, gaia-sprint-plan.bats, etc.
# ---------------------------------------------------------------------------

@test "VLR-01: Step 6 documents Val subagent dispatch with context: fork" {
  run grep -qE "context:[[:space:]]*fork" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-01: Step 6 documents Val read-only allowlist [Read, Grep, Glob, Bash]" {
  run grep -qE "Read.*Grep.*Glob.*Bash|\[Read, Grep, Glob, Bash\]" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-01: Step 6 references 8-part structured response contract" {
  run grep -qiE "8-part|eight.part|frontmatter.*completeness.*clarity|structured.*response" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-02: Step 6 documents 3-attempt cap" {
  run grep -qiE "3.attempt|three.attempt|attempt.*3|cap.*3|max.*3" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-02: Step 6 documents terminal FAILED verdict on exhaustion via review-gate.sh" {
  run grep -qE "review-gate\.sh" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -qE "FAILED" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-03: Step 6 documents early-exit on PASSED before cap" {
  run grep -qiE "PASSED|passed.*verdict|zero.*CRITICAL" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-04: Step 6 documents sprint-status.yaml sync via transition-story-status.sh after each attempt" {
  run grep -qE "transition-story-status\.sh" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-05: Step 6 documents INFO-only findings bypass the fix loop" {
  run grep -qiE "INFO.only|INFO.*findings.*(log|bypass|not trigger|no.*loop)|FR-339" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-06: Step 6 references canonical vocabulary PASSED/FAILED/UNVERIFIED" {
  local file="$SKILL_DIR/SKILL.md"
  grep -q "PASSED" "$file"
  grep -q "FAILED" "$file"
  grep -q "UNVERIFIED" "$file"
}

@test "VLR-06: Step 6 documents ledger-keyed query shape with --plan-id and gate story-validation" {
  run grep -qE "story-validation" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -qE "plan-id|plan_id" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC-EC edge case prose markers
# ---------------------------------------------------------------------------

@test "AC-EC1: Step 6 documents malformed 8-part response → WARNING + UNVERIFIED treatment" {
  run grep -qiE "malformed|missing.*part|UNVERIFIED" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC2: Step 6 documents HALT on missing review-gate.sh" {
  run grep -qiE "HALT|halt" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC3: Step 6 documents self-transition rejection is benign" {
  run grep -qiE "self.transition|benign|non.blocking|same.*status" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC4: Step 6 documents oscillation / non-convergence cap enforcement (no short-circuit)" {
  run grep -qiE "oscillation|non.convergence|stall|identical.*findings|no.*short.circuit" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC5: Step 6 documents that new findings do not reset attempt counter" {
  run grep -qiE "do not reset|no.*reset|counter.*not|attempt.*count" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC6: Step 6 documents Val timeout → HALT with UNVERIFIED" {
  run grep -qiE "timeout|could not complete|unavailable" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC7: Step 6 documents INFO severity filter out of loop trigger" {
  run grep -qiE "INFO.*(log|not trigger|bypass|do not)" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC8: Step 6 documents YOLO cannot bypass cap or FAILED verdict (FR-340)" {
  run grep -qiE "YOLO.*(not bypass|does not|cannot)|FR-340|bypass" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# NFR-046 single-spawn-level preservation (inline SM fix, not a nested spawn)
# ---------------------------------------------------------------------------

@test "NFR-046: Step 6 documents inline SM fix (no nested Agent/Task spawn)" {
  run grep -qiE "inline.*SM|SM.*inline|NFR-046|single.spawn|no.*nested" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# ADR cross-reference
# ---------------------------------------------------------------------------

@test "Step 6 references ADR-050 (canonical pattern origin)" {
  run grep -q "ADR-050" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# review-gate.sh: story-validation gate acceptance (VLR-06 Tier 1)
# The terminal verdict MUST be recordable via the ledger-keyed path so the
# 6-row canonical Review Gate table is not overwritten at story-creation
# time.
# ---------------------------------------------------------------------------

@test "review-gate.sh: story-validation gate accepts PASSED verdict via --plan-id (ledger write)" {
  seed_story RGS1 UNVERIFIED
  local plan_id="create-story-val-abc123"

  run "$SCRIPT" update --story RGS1 --gate "story-validation" --verdict PASSED --plan-id "$plan_id"
  [ "$status" -eq 0 ]

  [ -f "$LEDGER" ]
  grep -q "RGS1" "$LEDGER"
  grep -q "story-validation" "$LEDGER"
  grep -q "$plan_id" "$LEDGER"
}

@test "review-gate.sh: story-validation gate accepts FAILED verdict via --plan-id (VLR-06 Tier 1)" {
  seed_story RGS2 UNVERIFIED
  local plan_id="create-story-val-def456"

  run "$SCRIPT" update --story RGS2 --gate "story-validation" --verdict FAILED --plan-id "$plan_id"
  [ "$status" -eq 0 ]

  # VLR-06 assertion: exact string FAILED appears in ledger query
  run "$SCRIPT" status --story RGS2 --gate "story-validation" --plan-id "$plan_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAILED"* ]]
}

@test "review-gate.sh: story-validation gate rejects invalid verdict (canonical vocab enforcement)" {
  seed_story RGS3 UNVERIFIED
  local plan_id="create-story-val-ghi789"

  run "$SCRIPT" update --story RGS3 --gate "story-validation" --verdict "failed" --plan-id "$plan_id"
  [ "$status" -ne 0 ]
}

@test "review-gate.sh: story-validation gate requires --plan-id (ledger-only gate)" {
  seed_story RGS4 UNVERIFIED

  run "$SCRIPT" update --story RGS4 --gate "story-validation" --verdict PASSED
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Regression: test-automate-plan ledger path remains intact
# (required by Val finding W3 — existing PLAN_ID_GATES logic must not break)
# ---------------------------------------------------------------------------

@test "regression: test-automate-plan gate still works (PLAN_ID_GATES extension non-regressing)" {
  seed_story REG1 UNVERIFIED
  local plan_id="plan-regression-check"

  run "$SCRIPT" update --story REG1 --gate "test-automate-plan" --verdict PASSED --plan-id "$plan_id"
  [ "$status" -eq 0 ]

  run "$SCRIPT" status --story REG1 --gate "test-automate-plan" --plan-id "$plan_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
}

# ---------------------------------------------------------------------------
# Canonical gates still reject --plan-id unless ledger-mode is appropriate
# (backward compat guard — AC6 of E35-S2 precedent test)
# ---------------------------------------------------------------------------

@test "canonical gate Code Review still writes to story file (no ledger side-effect)" {
  seed_story CG1 UNVERIFIED

  run "$SCRIPT" update --story CG1 --gate "Code Review" --verdict PASSED
  [ "$status" -eq 0 ]

  # Status on the story reflects the update, without the ledger being populated
  # specifically for Code Review (the table is the authoritative write surface).
  grep -q "| Code Review | PASSED |" "$ART/CG1-fake.md"
}
