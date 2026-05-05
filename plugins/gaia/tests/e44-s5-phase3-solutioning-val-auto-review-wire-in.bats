#!/usr/bin/env bats
# e44-s5-phase3-solutioning-val-auto-review-wire-in.bats
#
# Script-verifiable coverage for E44-S5 — wiring the Val auto-fix loop
# (E44-S2 / ADR-058) into the 6 Phase 3 Solutioning artifact-producing
# skills:
#
#   - gaia-create-arch     -> docs/planning-artifacts/architecture.md
#                                                          (artifact_type=architecture)
#   - gaia-edit-arch       -> docs/planning-artifacts/architecture.md
#                                                          (artifact_type=architecture)
#   - gaia-review-api      -> docs/planning-artifacts/api-design-review-{date}.md
#                                                          (artifact_type=api-design-review)
#   - gaia-create-epics    -> docs/planning-artifacts/epics-and-stories.md
#                                                          (artifact_type=epics-and-stories)
#   - gaia-threat-model    -> docs/planning-artifacts/threat-model.md
#                                                          (artifact_type=threat-model)
#   - gaia-infra-design    -> docs/planning-artifacts/infrastructure-design.md
#                                                          (artifact_type=infrastructure-design)
#
# Story acceptance criteria covered (script-verifiable subset):
#   AC1 — auto-invocation step embedded after artifact-write
#   AC2 — canonical E44-S2 pattern referenced (E44-S2, ADR-058, 3-cap, iter=1)
#   AC4 — correct artifact_path + artifact_type per skill
#   AC5 — provenance reference back to E44-S2 + ADR-058
#   AC7 — gaia-create-arch wire-in does not displace Steps 10/11/12
#   AC8 — gaia-edit-arch wire-in attaches to FINAL Step 6 write (post-adversarial)
#   AC-EC3 — artifact-existence guard ("if not exists ... exit") embedded
#   AC-EC6 — Val-skill-availability guard ("Val auto-review unavailable")
#   AC-EC8 — YOLO hard-gate invariant referenced (no bypass branch)
#
# Mirrors the structure of e44-s3-phase1-val-auto-review-wire-in.bats and
# e44-s4-phase2-val-auto-review-wire-in.bats (sibling cluster stories).

load 'test_helper.bash'

setup() {
  common_setup
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export SKILLS_DIR
  PHASE3_SKILLS_LIST="gaia-create-arch gaia-edit-arch gaia-review-api gaia-create-epics gaia-threat-model gaia-infra-design"
  export PHASE3_SKILLS_LIST
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Pre-flight — all 6 Phase 3 Solutioning SKILL.md files exist and are readable
# ---------------------------------------------------------------------------

@test "preflight: all 6 Phase 3 Solutioning SKILL.md files exist" {
  for skill in $PHASE3_SKILLS_LIST; do
    [ -f "$SKILLS_DIR/$skill/SKILL.md" ]
    [ -r "$SKILLS_DIR/$skill/SKILL.md" ]
  done
}

# ---------------------------------------------------------------------------
# AC1 — Each SKILL.md embeds the Val Auto-Fix Loop step
# ---------------------------------------------------------------------------

@test "AC1: gaia-create-arch SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-create-arch/SKILL.md"
}

@test "AC1: gaia-edit-arch SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-edit-arch/SKILL.md"
}

@test "AC1: gaia-review-api SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-review-api/SKILL.md"
}

@test "AC1: gaia-create-epics SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-create-epics/SKILL.md"
}

@test "AC1: gaia-threat-model SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-threat-model/SKILL.md"
}

@test "AC1: gaia-infra-design SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-infra-design/SKILL.md"
}

@test "AC1: each Phase 3 Solutioning skill invokes /gaia-val-validate with artifact_path and artifact_type" {
  for skill in $PHASE3_SKILLS_LIST; do
    grep -q '/gaia-val-validate' "$SKILLS_DIR/$skill/SKILL.md"
    grep -q 'artifact_path' "$SKILLS_DIR/$skill/SKILL.md"
    grep -q 'artifact_type' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC4 — Correct artifact_type per skill
# ---------------------------------------------------------------------------

@test "AC4: gaia-create-arch uses artifact_type=architecture" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*architecture' "$SKILLS_DIR/gaia-create-arch/SKILL.md"
}

@test "AC4: gaia-edit-arch uses artifact_type=architecture" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*architecture' "$SKILLS_DIR/gaia-edit-arch/SKILL.md"
}

@test "AC4: gaia-review-api uses artifact_type=api-design-review" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*api-design-review' "$SKILLS_DIR/gaia-review-api/SKILL.md"
}

@test "AC4: gaia-create-epics uses artifact_type=epics-and-stories" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*epics-and-stories' "$SKILLS_DIR/gaia-create-epics/SKILL.md"
}

@test "AC4: gaia-threat-model uses artifact_type=threat-model" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*threat-model' "$SKILLS_DIR/gaia-threat-model/SKILL.md"
}

@test "AC4: gaia-infra-design uses artifact_type=infrastructure-design" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*infrastructure-design' "$SKILLS_DIR/gaia-infra-design/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC4 — Correct artifact_path per skill
# ---------------------------------------------------------------------------

@test "AC4: gaia-create-arch references docs/planning-artifacts/architecture.md artifact_path" {
  grep -q 'docs/planning-artifacts/architecture.md' "$SKILLS_DIR/gaia-create-arch/SKILL.md"
}

@test "AC4: gaia-edit-arch references docs/planning-artifacts/architecture.md artifact_path" {
  grep -q 'docs/planning-artifacts/architecture.md' "$SKILLS_DIR/gaia-edit-arch/SKILL.md"
}

@test "AC4: gaia-review-api references api-design-review-{date} artifact_path" {
  grep -qE 'api-design-review-\{date\}' "$SKILLS_DIR/gaia-review-api/SKILL.md"
}

@test "AC4: gaia-create-epics references docs/planning-artifacts/epics-and-stories.md artifact_path" {
  grep -q 'docs/planning-artifacts/epics-and-stories.md' "$SKILLS_DIR/gaia-create-epics/SKILL.md"
}

@test "AC4: gaia-threat-model references docs/planning-artifacts/threat-model.md artifact_path" {
  grep -q 'docs/planning-artifacts/threat-model.md' "$SKILLS_DIR/gaia-threat-model/SKILL.md"
}

@test "AC4: gaia-infra-design references docs/planning-artifacts/infrastructure-design.md artifact_path" {
  grep -q 'docs/planning-artifacts/infrastructure-design.md' "$SKILLS_DIR/gaia-infra-design/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC8 (no val_validate_output flag introduced) — Phase 3 wire-in is direct-call only
# ---------------------------------------------------------------------------

@test "AC8: no Phase 3 Solutioning SKILL.md introduces val_validate_output flag" {
  for skill in $PHASE3_SKILLS_LIST; do
    ! grep -q 'val_validate_output' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC2 / AC5 — Provenance and 3-iteration cap referenced
# ---------------------------------------------------------------------------

@test "AC5: each Phase 3 Solutioning skill references E44-S2 (pattern provenance)" {
  for skill in $PHASE3_SKILLS_LIST; do
    grep -q 'E44-S2' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC5: each Phase 3 Solutioning skill references ADR-058 (decision provenance)" {
  for skill in $PHASE3_SKILLS_LIST; do
    grep -q 'ADR-058' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC2: each Phase 3 Solutioning skill documents iteration counter (iteration = 1)" {
  for skill in $PHASE3_SKILLS_LIST; do
    grep -qE 'iteration[[:space:]]*=[[:space:]]*1' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC2: each Phase 3 Solutioning skill documents the 3-iteration cap" {
  for skill in $PHASE3_SKILLS_LIST; do
    grep -qE 'iteration[[:space:]]*<=[[:space:]]*3' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC2: each Phase 3 Solutioning skill cites the canonical Auto-Fix Loop Pattern anchor" {
  for skill in $PHASE3_SKILLS_LIST; do
    grep -q 'Auto-Fix Loop Pattern' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC3 — Artifact-existence guard
# ---------------------------------------------------------------------------

@test "AC-EC3: each Phase 3 Solutioning skill includes an artifact-existence guard" {
  for skill in $PHASE3_SKILLS_LIST; do
    grep -qE 'if[[:space:]]+not[[:space:]]+exists' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC6 — Val-skill-availability guard with documented warning text
# ---------------------------------------------------------------------------

@test "AC-EC6: each Phase 3 Solutioning skill emits the canonical missing-Val warning" {
  for skill in $PHASE3_SKILLS_LIST; do
    grep -q 'Val auto-review unavailable' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC8 — YOLO hard-gate invariant; no bypass branch introduced
# ---------------------------------------------------------------------------

@test "AC-EC8: each Phase 3 Solutioning skill references the YOLO hard-gate invariant" {
  for skill in $PHASE3_SKILLS_LIST; do
    grep -qE 'YOLO' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# Loop placement — wire-in step appears AFTER the artifact-write step
# AC7: gaia-create-arch Val loop runs after Step 9 (Generate Output) and
#      BEFORE Step 11 (Adversarial Review) — preserves Step 10/11/12 order.
# AC8: gaia-edit-arch Val loop runs after Step 6 (Save and Review Gate) —
#      after the FINAL post-adversarial write within Step 6.
# AC1: gaia-review-api Val loop runs after Step 5 (Report).
# AC1: gaia-create-epics Val loop runs after Step 8 (Generate Output) and
#      BEFORE Step 10 (Brownfield onboarding) / Step 11+ (Edge case / Adv).
# AC1: gaia-threat-model Val loop runs after Step 7 (Generate Output).
# AC1: gaia-infra-design Val loop runs after Step 6 (Generate Output).
# ---------------------------------------------------------------------------

@test "AC7 placement: gaia-create-arch Val loop step appears after Step 9 (Generate Output) and before Adversarial Review" {
  local skill="$SKILLS_DIR/gaia-create-arch/SKILL.md"
  local write_line val_line adv_line
  write_line="$(grep -n '^### Step 9 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  adv_line="$(grep -n 'Adversarial Review' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ -n "$adv_line" ]
  [ "$val_line" -gt "$write_line" ]
  [ "$val_line" -lt "$adv_line" ]
}

@test "AC8 placement: gaia-edit-arch Val loop step appears after Step 6 (Save and Review Gate)" {
  local skill="$SKILLS_DIR/gaia-edit-arch/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 6 — Save and Review Gate' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

@test "AC1 placement: gaia-review-api Val loop step appears after Step 5 (Report)" {
  local skill="$SKILLS_DIR/gaia-review-api/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 5 — Report' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

@test "AC1 placement: gaia-create-epics Val loop step appears after Step 8 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-create-epics/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 8 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

@test "AC1 placement: gaia-threat-model Val loop step appears after Step 7 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-threat-model/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 7 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

@test "AC1 placement: gaia-infra-design Val loop step appears after Step 6 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-infra-design/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 6 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

# ---------------------------------------------------------------------------
# Step renumbering invariants — keep vcp-cpt expectations and step counts
# in sync with the wire-in.
# ---------------------------------------------------------------------------

@test "step-count: gaia-create-arch has 13 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-create-arch/SKILL.md")
  [ "$count" = "13" ]
}

@test "step-count: gaia-edit-arch has 9 Step headings after wire-in" {
  # 9 steps: 8 from Val auto-review wire-in + 1 added by E53-S244 (Re-shard).
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-edit-arch/SKILL.md")
  [ "$count" = "9" ]
}

@test "step-count: gaia-review-api has 6 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-review-api/SKILL.md")
  [ "$count" = "6" ]
}

@test "step-count: gaia-create-epics has 12 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-create-epics/SKILL.md")
  [ "$count" = "12" ]
}

@test "step-count: gaia-threat-model has 8 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-threat-model/SKILL.md")
  [ "$count" = "8" ]
}

@test "step-count: gaia-infra-design has 7 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-infra-design/SKILL.md")
  [ "$count" = "7" ]
}

# ---------------------------------------------------------------------------
# Checkpoint emission — each new Val-loop step emits one
# write-checkpoint.sh invocation (E43-S2 wire-in convention).
# ---------------------------------------------------------------------------

@test "checkpoint: gaia-create-arch Val loop step emits one write-checkpoint.sh invocation at step 10" {
  grep -qE '^> `!scripts/write-checkpoint\.sh gaia-create-arch 10 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-create-arch/SKILL.md"
}

@test "checkpoint: gaia-edit-arch Val loop step emits one write-checkpoint.sh invocation at step 7" {
  grep -qE '^> `!scripts/write-checkpoint\.sh gaia-edit-arch 7 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-edit-arch/SKILL.md"
}

@test "checkpoint: gaia-review-api Val loop step emits one write-checkpoint.sh invocation at step 6" {
  grep -qE '^> `!scripts/write-checkpoint\.sh gaia-review-api 6 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-review-api/SKILL.md"
}

@test "checkpoint: gaia-create-epics Val loop step emits one write-checkpoint.sh invocation at step 9" {
  grep -qE '^> `!scripts/write-checkpoint\.sh gaia-create-epics 9 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-create-epics/SKILL.md"
}

@test "checkpoint: gaia-threat-model Val loop step emits one write-checkpoint.sh invocation at step 8" {
  grep -qE '^> `!scripts/write-checkpoint\.sh gaia-threat-model 8 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-threat-model/SKILL.md"
}

@test "checkpoint: gaia-infra-design Val loop step emits one write-checkpoint.sh invocation at step 7" {
  grep -qE '^> `!scripts/write-checkpoint\.sh gaia-infra-design 7 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-infra-design/SKILL.md"
}
