#!/usr/bin/env bats
# gaia-validate-story.bats — unit tests for gaia-validate-story skill Step 3
# (Val subagent + 3-attempt SM fix loop per ADR-050).
#
# Covers: SKILL.md frontmatter, Step 3 prose anchors (VLR-01..VLR-07
# behavioral markers, AC-EC1..AC-EC10 edge-case markers), review-gate.sh
# "story-validation" ledger gate acceptance (VLR-06 Tier 1), and NFR-046
# inline SM fix preservation.
#
# VLR-07 is the dedicated scenario for E33-S2: validate-story fix loop
# convergence within 3 attempts.
#
# Pattern: flat-file convention matching peers gaia-create-story.bats,
# gaia-dev-story.bats, gaia-sprint-plan.bats.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-validate-story"
SCRIPT="$BATS_TEST_DIRNAME/../scripts/review-gate.sh"

setup() {
  common_setup
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$ART"
  LEDGER="$TEST_TMP/.review-gate-ledger"
  export REVIEW_GATE_LEDGER="$LEDGER"
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
# SKILL.md frontmatter and structural checks (AC prereqs)
# ---------------------------------------------------------------------------

@test "SKILL.md exists for gaia-validate-story" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "SKILL.md frontmatter: name gaia-validate-story" {
  run awk '/^---$/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-validate-story"* ]]
}

@test "SKILL.md frontmatter: allowed-tools includes Read Write Edit Bash (inline SM fix requirement, NFR-046)" {
  run awk '/^---$/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"allowed-tools:"* ]]
  [[ "$output" == *"Read"* ]]
  [[ "$output" == *"Write"* ]]
  [[ "$output" == *"Edit"* ]]
  [[ "$output" == *"Bash"* ]]
}

@test "POST-E87-S3: SKILL.md frontmatter migrated off context: fork (ADR-104)" {
  # Originally pinned `context: fork preserved` (AC4, AC-EC2, NFR-046) under
  # the fork-based dispatch model. E87-S3 (Val Bridge Migration, ADR-104)
  # retargets /gaia-validate-story to main-turn Agent dispatch — the
  # frontmatter no longer declares `context: fork`. The test now pins the
  # post-migration invariant: frontmatter is absent of `context: fork`.
  run awk '/^---$/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [ -n "$output" ]
  ! grep -Eq '^context:[[:space:]]*fork' <<< "$output"
}

# ---------------------------------------------------------------------------
# Step 3 prose anchors (VLR behavioral markers)
# Tests validate that SKILL.md Step 3 contains the required ADR-050 pattern
# language so future refactors cannot silently drop the fix loop.
# These are prose-anchor tests -- common pattern across gaia-create-story.bats.
# ---------------------------------------------------------------------------

@test "POST-E87-S3: SKILL.md documents main-turn Agent-tool dispatch + envelope assert (ADR-104)" {
  # Originally VLR-01 asserted the body prose contained `context: fork`
  # under the fork-based dispatch model. E87-S3 retargets the body to
  # main-turn Agent-tool dispatch with the envelope-assert step. The test
  # now pins the post-migration invariants: (a) the ADR-104 reference is
  # present, and (b) the `assert_agent_envelope` call is referenced as the
  # post-dispatch HALT gate.
  grep -q 'ADR-104' "$SKILL_DIR/SKILL.md"
  grep -q 'assert_agent_envelope' "$SKILL_DIR/SKILL.md"
}

@test "VLR-01: SKILL.md documents Val read-only allowlist [Read, Grep, Glob, Bash]" {
  run grep -qE "Read.*Grep.*Glob.*Bash|\[Read, Grep, Glob, Bash\]" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-02: Step 3 documents 3-attempt cap" {
  run grep -qiE "3.attempt|three.attempt|attempt.*3|cap.*3|max.*3" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-02: Step 3 documents terminal FAILED verdict on exhaustion via review-gate.sh" {
  run grep -qE "review-gate\.sh" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -qE "FAILED" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-03: Step 3 documents early-exit on PASSED before cap" {
  run grep -qiE "PASSED|passed.*verdict|zero.*CRITICAL" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-04: Step 3 documents sprint-status.yaml sync via sprint-state.sh after each attempt" {
  run grep -qE "sprint-state\.sh" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-05: Step 3 documents INFO-only findings bypass the fix loop" {
  run grep -qiE "INFO.only|INFO.*findings.*(log|bypass|not trigger|no.*loop)|FR-339" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-06: Step 3 references canonical vocabulary PASSED/FAILED/UNVERIFIED" {
  local file="$SKILL_DIR/SKILL.md"
  grep -q "PASSED" "$file"
  grep -q "FAILED" "$file"
  grep -q "UNVERIFIED" "$file"
}

@test "VLR-06: Step 3 documents ledger-keyed query shape with --plan-id and gate story-validation" {
  run grep -qE "story-validation" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -qE "plan-id|plan_id" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "VLR-07: Step 3 documents fix loop convergence within 3 attempts (E33-S2 dedicated scenario)" {
  # VLR-07 is dedicated to this story: the validate-story skill must document
  # the fix loop that converges within 3 attempts.
  run grep -qiE "fix.loop|fix.*attempt|SM.*fix|inline.*fix" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -qiE "3.attempt|attempt.*3|cap.*3" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Step renumbering checks
# Old Step 3 (Record Outcome) -> new Step 4
# Old Step 4 (Report Results) -> new Step 5
# ---------------------------------------------------------------------------

@test "renumbering: old Step 3 (Record Outcome) is now Step 4" {
  run grep -qE "Step 4.*Record Outcome|Step 4.*review-gate\.sh" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "renumbering: old Step 4 (Report Results) is now Step 5" {
  run grep -qE "Step 5.*Report Results" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC-EC edge case prose markers
# ---------------------------------------------------------------------------

@test "AC-EC1: Step 3 documents Edit/Write scoped to story file + review-gate.sh output (SR-24)" {
  run grep -qiE "scoped|story file.*review-gate|SR-24|allowlist" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC2: Step 3 documents no nested subagent spawn (NFR-046, SR-25)" {
  run grep -qiE "no.*nested|inline.*SM|NFR-046|SR-25|no.*Agent.*tool" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC3: Step 3 documents YOLO cannot bypass cap or FAILED verdict (FR-340, SR-23)" {
  run grep -qiE "YOLO.*(not bypass|does not|cannot)|FR-340|SR-23" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC4: Step 3 documents Val timeout -> HALT with UNVERIFIED" {
  run grep -qiE "timeout|could not complete|unavailable" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC5: Step 3 documents oscillation / non-convergence cap enforcement (no short-circuit)" {
  run grep -qiE "oscillation|non.convergence|stall|identical.*finding|no.*short.circuit" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC6: Step 3 documents self-transition rejection is benign" {
  run grep -qiE "self.transition|benign|non.blocking" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC7: Step 3 documents INFO severity filter out of loop trigger (FR-339)" {
  run grep -qiE "INFO.*(log|not trigger|bypass|do not)|FR-339" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC8: Step 3 documents adversarial path-escape write rejection (T-27, T-29)" {
  run grep -qiE "adversarial|path.escape|fail.closed|T-27|T-29|out.of.scope" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC9: Step 3 documents HALT on missing review-gate.sh" {
  run grep -qiE "review-gate\.sh.*(missing|not.*present|not.*executable)|HALT.*review-gate" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC-EC10: Step 3 documents interactive-only known limitation (GR-VS-5 deferred)" {
  run grep -qiE "interactive.only|GR-VS-5|deferred.*YOLO" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# NFR-046 single-spawn-level preservation (inline SM fix, not a nested spawn)
# ---------------------------------------------------------------------------

@test "NFR-046: SKILL.md documents inline SM fix (no nested Agent/Task spawn)" {
  run grep -qiE "inline.*SM|SM.*inline|NFR-046|single.spawn|no.*nested" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# ADR cross-reference
# ---------------------------------------------------------------------------

@test "Step 3 references ADR-050 (canonical pattern origin)" {
  run grep -q "ADR-050" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "Step 3 references Component 2 (finding classification) explicitly" {
  # INFO #1 autofix: Step 3 must note that Component 1 (Val dispatch) is
  # fulfilled by the preceding Step 2.
  run grep -qiE "Component.*1.*Step 2|Component.*2.*finding.*classification" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Critical Rules section checks
# ---------------------------------------------------------------------------

@test "Critical Rules: SR-23 referenced (3-attempt cap; YOLO cannot bypass)" {
  run grep -qE "SR-23" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "Critical Rules: SR-24 referenced (tool allowlist scoped)" {
  run grep -qE "SR-24" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "Critical Rules: SR-25 referenced (inline fix only; no nested subagent)" {
  run grep -qE "SR-25" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# review-gate.sh: story-validation gate acceptance for validate-story
# (VLR-06 Tier 1 — terminal verdict via ledger-keyed path)
# ---------------------------------------------------------------------------

@test "review-gate.sh: story-validation gate accepts PASSED verdict with validate-story plan-id" {
  seed_story VRS1 UNVERIFIED
  local plan_id="validate-story-val-abc123"

  run "$SCRIPT" update --story VRS1 --gate "story-validation" --verdict PASSED --plan-id "$plan_id"
  [ "$status" -eq 0 ]

  [ -f "$LEDGER" ]
  grep -q "VRS1" "$LEDGER"
  grep -q "story-validation" "$LEDGER"
  grep -q "$plan_id" "$LEDGER"
}

@test "review-gate.sh: story-validation gate accepts FAILED verdict with validate-story plan-id (VLR-06)" {
  seed_story VRS2 UNVERIFIED
  local plan_id="validate-story-val-def456"

  run "$SCRIPT" update --story VRS2 --gate "story-validation" --verdict FAILED --plan-id "$plan_id"
  [ "$status" -eq 0 ]

  # VLR-06 assertion: exact string FAILED appears in ledger query
  run "$SCRIPT" status --story VRS2 --gate "story-validation" --plan-id "$plan_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAILED"* ]]
}

@test "review-gate.sh: story-validation gate accepts UNVERIFIED verdict with validate-story plan-id" {
  seed_story VRS3 UNVERIFIED
  local plan_id="validate-story-val-ghi789"

  run "$SCRIPT" update --story VRS3 --gate "story-validation" --verdict UNVERIFIED --plan-id "$plan_id"
  [ "$status" -eq 0 ]

  run "$SCRIPT" status --story VRS3 --gate "story-validation" --plan-id "$plan_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
}

@test "review-gate.sh: story-validation ledger uses {timestamp} placeholder vocabulary" {
  # INFO #2 autofix: validate-story uses {timestamp} placeholder (not
  # validate-story-val-{ts}). Verify the SKILL.md uses {timestamp}.
  run grep -qE "\{timestamp\}" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Regression: canonical six Review Gate rows untouched by ledger writes
# (story-validation uses the ledger path; the table rows belong to the
# six downstream review commands)
# ---------------------------------------------------------------------------

@test "regression: ledger write does not modify story file Review Gate table rows" {
  seed_story REGRV1 UNVERIFIED
  local plan_id="validate-story-val-reg1"

  # Capture story content before ledger write
  local before
  before="$(cat "$ART/REGRV1-fake.md")"

  run "$SCRIPT" update --story REGRV1 --gate "story-validation" --verdict PASSED --plan-id "$plan_id"
  [ "$status" -eq 0 ]

  # Story file must be unchanged (ledger writes go to .review-gate-ledger, not the table)
  local after
  after="$(cat "$ART/REGRV1-fake.md")"
  [ "$before" = "$after" ]
}
