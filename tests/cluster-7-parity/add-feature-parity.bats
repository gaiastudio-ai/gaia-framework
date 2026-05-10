#!/usr/bin/env bats
# add-feature-parity.bats — E48-S1 parity + structure tests for
# gaia-add-feature (Val review gate + assessment-doc artifact restoring
# validation gates swallowed by subagents under ADR-063).
#
# Refs: E48-S1, FR-362, ADR-037, ADR-041, ADR-042, ADR-045, ADR-063,
#       ADR-067, NFR-046, NFR-053
#
# Coverage:
#   AC1 — urgency + driver intake vocabulary in Step 1
#   AC2 — feature_id format `AF-{date}-{N}`
#   AC3 — Val review gate with halt-on-CRITICAL semantics
#   AC4 — assessment-doc artifact emit at
#         docs/planning-artifacts/assessment-{feature_id}.md

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SKILL="gaia-add-feature"
  SKILL_DIR="$SKILLS_DIR/$SKILL"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
}

# ---------- Existence + frontmatter sanity ----------

@test "E48-S1: gaia-add-feature SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

@test "E48-S1: gaia-add-feature frontmatter has name" {
  head -20 "$SKILL_FILE" | grep -q '^name: gaia-add-feature'
}

@test "E48-S1: gaia-add-feature frontmatter declares context: fork" {
  head -20 "$SKILL_FILE" | grep -q '^context: fork'
}

@test "E48-S1: gaia-add-feature frontmatter allowed-tools includes Agent" {
  head -20 "$SKILL_FILE" | grep -q '^allowed-tools:.*Agent'
}

# ---------- AC1: urgency + driver intake vocabulary ----------

@test "E48-S1: Step 1 prompts for urgency vocabulary (critical/high/medium/low)" {
  grep -qiE 'urgency' "$SKILL_FILE"
  grep -qE 'critical.*high.*medium.*low|critical / high / medium / low' "$SKILL_FILE"
}

@test "E48-S1: Step 1 prompts for driver vocabulary (user-request/bug-report/tech-debt/opportunity)" {
  grep -qiE 'driver' "$SKILL_FILE"
  grep -qE 'user-request.*bug-report.*tech-debt.*opportunity|user-request / bug-report / tech-debt / opportunity' "$SKILL_FILE"
}

# ---------- AC2: feature_id format AF-{date}-{N} ----------

@test "E48-S1: feature_id format is AF-{date}-{N}" {
  grep -qE 'AF-\{date\}-\{N\}|AF-\{YYYY-MM-DD\}-\{N\}' "$SKILL_FILE"
}

@test "E48-S1: feature_id generation is described in Step 1" {
  grep -qiE 'feature_id|feature id' "$SKILL_FILE"
}

# ---------- AC3: Val review gate + verdict surfacing (ADR-063) ----------

@test "E48-S1: SKILL.md includes Subagent Dispatch Contract section" {
  grep -qE '^## Subagent Dispatch Contract|^### Subagent Dispatch Contract' "$SKILL_FILE"
}

@test "E48-S1: SKILL.md surfaces verdict (PASS/WARNING/CRITICAL)" {
  grep -q 'CRITICAL' "$SKILL_FILE"
  grep -q 'WARNING' "$SKILL_FILE"
  grep -qE 'PASS|status' "$SKILL_FILE"
}

@test "E48-S1: SKILL.md codifies halt-on-CRITICAL semantics" {
  grep -qiE 'halt.*CRITICAL|CRITICAL.*halt' "$SKILL_FILE"
}

@test "E48-S1: SKILL.md references ADR-037 structured return schema" {
  grep -q 'ADR-037' "$SKILL_FILE"
}

@test "E48-S1: SKILL.md declares Val review gate step" {
  grep -qiE 'Val review gate|Val.*gate|review gate.*Val' "$SKILL_FILE"
}

@test "E48-S1: SKILL.md invokes Val with context: fork" {
  grep -qE 'context: fork|`context: fork`' "$SKILL_FILE"
}

# ---------- ADR-067: YOLO behavior section ----------

@test "E48-S1: SKILL.md includes YOLO Behavior section" {
  grep -qE '^## YOLO Behavior|^### YOLO Behavior|^## YOLO Mode|^### YOLO Mode' "$SKILL_FILE"
}

@test "E48-S1: YOLO mode auto-displays verdict but halts on CRITICAL" {
  grep -qiE 'CRITICAL.*still.*halt|CRITICAL.*halt.*YOLO|YOLO.*CRITICAL.*halt' "$SKILL_FILE"
}

# ---------- AC4: assessment-doc artifact emit ----------

@test "E48-S1: SKILL.md declares assessment-doc artifact path" {
  grep -qE 'docs/planning-artifacts/assessment-\{feature_id\}\.md' "$SKILL_FILE"
}

@test "E48-S1: assessment-doc declares Classification section" {
  grep -qiE 'classification' "$SKILL_FILE"
}

@test "E48-S1: assessment-doc declares Affected Artifacts section" {
  grep -qiE 'affected[- ]artifacts' "$SKILL_FILE"
}

@test "E48-S1: assessment-doc declares Cascade Plan section" {
  grep -qiE 'cascade[- ]plan|cascade plan' "$SKILL_FILE"
}

@test "E48-S1: assessment-doc declares Val Findings Summary section" {
  grep -qiE 'val[- ]findings|val findings|findings summary' "$SKILL_FILE"
}

@test "E48-S1: assessment-doc emit is gated on no-CRITICAL" {
  grep -qiE 'no CRITICAL.*assessment[- ]doc|assessment[- ]doc.*after.*cascade|no.*CRITICAL.*emit|cascade.*completes.*successfully' "$SKILL_FILE"
}

# ---------- ADR refs and traceability ----------

@test "E48-S1: SKILL.md references ADR-041 (Native Execution)" {
  grep -q 'ADR-041' "$SKILL_FILE"
}

@test "E48-S1: SKILL.md references ADR-042 (Scripts-over-LLM)" {
  grep -q 'ADR-042' "$SKILL_FILE"
}

@test "E48-S1: SKILL.md references ADR-045 (fork-context isolation)" {
  grep -q 'ADR-045' "$SKILL_FILE"
}

@test "E48-S1: SKILL.md references ADR-063 (Subagent Dispatch Contract)" {
  grep -q 'ADR-063' "$SKILL_FILE"
}

@test "E48-S1: SKILL.md references ADR-067 (YOLO Mode Contract)" {
  grep -q 'ADR-067' "$SKILL_FILE"
}

# ---------- Linter compliance ----------

@test "E48-S1: lint-skill-frontmatter.sh passes on gaia-add-feature SKILL.md" {
  cd "$REPO_ROOT"
  bash .github/scripts/lint-skill-frontmatter.sh
}

# ---------- Layout constraints ----------

@test "E48-S1: gaia-add-feature/ has no workflow.yaml (native skill)" {
  [ ! -f "$SKILL_DIR/workflow.yaml" ]
}

@test "E48-S1: gaia-add-feature/ has no instructions.xml (native skill)" {
  [ ! -f "$SKILL_DIR/instructions.xml" ]
}

# ---------- ADR-042 no-new-scripts: only setup/finalize/write-val-sentinel allowed ----------
# E83-S1 amendment: write-val-sentinel.sh is the script-side fail-closed
# primitive for the Val gate. AC4 of E83-S1 requires that the sentinel write
# go through a deterministic helper rather than hand-rolled JSON inline in
# finalize.sh, so this carve-out is part of the story's explicit scope.

@test "E48-S1: gaia-add-feature scripts/ contains only allowlisted scripts" {
  cd "$SKILL_DIR/scripts"
  count="$(ls -1 | wc -l | tr -d ' ')"
  [ "$count" = "3" ]
  [ -f "setup.sh" ]
  [ -f "finalize.sh" ]
  [ -f "write-val-sentinel.sh" ]
}
