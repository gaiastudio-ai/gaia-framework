#!/usr/bin/env bats
# e44-s4-phase2-val-auto-review-wire-in.bats
#
# Script-verifiable coverage for E44-S4 — wiring the Val auto-fix loop
# (E44-S2 / ADR-058) into the 3 Phase 2 / product-brief artifact-producing
# skills:
#
#   - gaia-create-prd      -> docs/planning-artifacts/prd.md       (artifact_type=prd)
#   - gaia-create-ux       -> docs/planning-artifacts/ux-design.md (artifact_type=ux-design)
#   - gaia-product-brief   -> docs/creative-artifacts/product-brief-{slug}.md
#                                                                  (artifact_type=product-brief)
#
# Story acceptance criteria covered (script-verifiable subset):
#   AC1 — auto-invocation step embedded after artifact-write
#   AC3 — create-prd Val invocation runs BEFORE Step 12 (Adversarial Review)
#   AC4 — create-ux Val invocation runs after Step 10 (primary save)
#   AC5 — product-brief Val invocation runs after Step 8 write
#   AC8 — deprecated `val_validate_output` flag absent from all 3 SKILL.md
#   AC-EC3 — artifact-existence guard ("if not exists ... exit") embedded
#   AC-EC6 — Val-skill-availability guard ("Val auto-review unavailable")
#   AC-EC8 — YOLO hard-gate invariant referenced (no bypass branch)
#
# Mirrors the structure of e44-s3-phase1-val-auto-review-wire-in.bats
# (E44-S3 sibling story, PR #252).

load 'test_helper.bash'

setup() {
  common_setup
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export SKILLS_DIR
  PHASE2_SKILLS_LIST="gaia-create-prd gaia-create-ux gaia-product-brief"
  export PHASE2_SKILLS_LIST
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Pre-flight — all 3 Phase 2 SKILL.md files exist and are readable
# ---------------------------------------------------------------------------

@test "preflight: all 3 Phase 2 SKILL.md files exist" {
  for skill in $PHASE2_SKILLS_LIST; do
    [ -f "$SKILLS_DIR/$skill/SKILL.md" ]
    [ -r "$SKILLS_DIR/$skill/SKILL.md" ]
  done
}

# ---------------------------------------------------------------------------
# AC1 — Each SKILL.md embeds the Val Auto-Fix Loop step
# ---------------------------------------------------------------------------

@test "AC1: gaia-create-prd SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-create-prd/SKILL.md"
}

@test "AC1: gaia-create-ux SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-create-ux/SKILL.md"
}

@test "AC1: gaia-product-brief SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-product-brief/SKILL.md"
}

@test "AC1: each Phase 2 skill invokes /gaia-val-validate with artifact_path and artifact_type" {
  for skill in $PHASE2_SKILLS_LIST; do
    grep -q '/gaia-val-validate' "$SKILLS_DIR/$skill/SKILL.md"
    grep -q 'artifact_path' "$SKILLS_DIR/$skill/SKILL.md"
    grep -q 'artifact_type' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC1: gaia-create-prd uses artifact_type=prd" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*prd' "$SKILLS_DIR/gaia-create-prd/SKILL.md"
}

@test "AC1: gaia-create-ux uses artifact_type=ux-design" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*ux-design' "$SKILLS_DIR/gaia-create-ux/SKILL.md"
}

@test "AC1: gaia-product-brief uses artifact_type=product-brief" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*product-brief' "$SKILLS_DIR/gaia-product-brief/SKILL.md"
}

@test "AC1: gaia-create-prd references prd.md artifact_path (canonical post-AF-21-10)" {
  # AF-2026-05-21-10 canonicalized this path. Accept canonical or legacy.
  grep -qE '(docs/planning-artifacts|\.gaia/artifacts/planning-artifacts)/prd\.md' "$SKILLS_DIR/gaia-create-prd/SKILL.md"
}

@test "AC1: gaia-create-ux references ux-design.md artifact_path (canonical post-AF-21-X)" {
  # Future AF will canonicalize this path. Accept canonical or legacy.
  grep -qE '(docs/planning-artifacts|\.gaia/artifacts/planning-artifacts)/ux-design\.md' "$SKILLS_DIR/gaia-create-ux/SKILL.md"
}

@test "AC1: gaia-product-brief references product-brief-{slug}.md artifact_path" {
  grep -q 'product-brief-{slug}.md' "$SKILLS_DIR/gaia-product-brief/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC8 — Deprecated flag `val_validate_output` absent from all 3 SKILL.md
# ---------------------------------------------------------------------------

@test "AC8: gaia-create-prd SKILL.md does NOT use val_validate_output flag" {
  ! grep -q 'val_validate_output' "$SKILLS_DIR/gaia-create-prd/SKILL.md"
}

@test "AC8: gaia-create-ux SKILL.md does NOT use val_validate_output flag" {
  ! grep -q 'val_validate_output' "$SKILLS_DIR/gaia-create-ux/SKILL.md"
}

@test "AC8: gaia-product-brief SKILL.md does NOT use val_validate_output flag" {
  ! grep -q 'val_validate_output' "$SKILLS_DIR/gaia-product-brief/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC2 / AC5 (E44-S2 inheritance) — provenance and 3-iteration cap referenced
# ---------------------------------------------------------------------------

@test "AC2: each Phase 2 skill references E44-S2 (pattern provenance)" {
  for skill in $PHASE2_SKILLS_LIST; do
    grep -q 'E44-S2' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC2: each Phase 2 skill references ADR-058 (decision provenance)" {
  for skill in $PHASE2_SKILLS_LIST; do
    grep -q 'ADR-058' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC2: each Phase 2 skill documents iteration counter (iteration = 1)" {
  for skill in $PHASE2_SKILLS_LIST; do
    grep -q -E 'iteration[[:space:]]*=[[:space:]]*1' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC2: each Phase 2 skill documents the 3-iteration cap" {
  for skill in $PHASE2_SKILLS_LIST; do
    grep -q -E 'iteration[[:space:]]*<=[[:space:]]*3' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC2: each Phase 2 skill cites the canonical Auto-Fix Loop Pattern anchor" {
  for skill in $PHASE2_SKILLS_LIST; do
    grep -q 'Auto-Fix Loop Pattern' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC3 — Artifact-existence guard
# ---------------------------------------------------------------------------

@test "AC-EC3: each Phase 2 skill includes an artifact-existence guard" {
  for skill in $PHASE2_SKILLS_LIST; do
    grep -q -E 'if[[:space:]]+not[[:space:]]+exists' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC6 — Val-skill-availability guard with documented warning text
# ---------------------------------------------------------------------------

@test "AC-EC6: each Phase 2 skill emits the canonical missing-Val warning" {
  for skill in $PHASE2_SKILLS_LIST; do
    grep -q 'Val auto-review unavailable' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC8 — YOLO hard-gate invariant; no bypass branch introduced
# ---------------------------------------------------------------------------

@test "AC-EC8: each Phase 2 skill references the YOLO hard-gate invariant" {
  for skill in $PHASE2_SKILLS_LIST; do
    grep -q -E 'YOLO' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# Loop placement — wire-in step appears AFTER the artifact-write step
# AC3: create-prd Val loop runs after Step 11 (Generate Output) and BEFORE
#      Step 12+ (which becomes Adversarial Review after renumbering).
# AC4: create-ux Val loop runs after Step 10 (Generate Output).
# AC5: product-brief Val loop runs after Step 8 (Generate Output).
# ---------------------------------------------------------------------------

@test "AC3 placement: gaia-create-prd Val loop step appears after Step 11 (Generate Output) and before Adversarial Review" {
  local skill="$SKILLS_DIR/gaia-create-prd/SKILL.md"
  local write_line val_line adv_line
  write_line="$(grep -n '^### Step 11 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  adv_line="$(grep -n 'Adversarial Review' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ -n "$adv_line" ]
  [ "$val_line" -gt "$write_line" ]
  [ "$val_line" -lt "$adv_line" ]
}

@test "AC4 placement: gaia-create-ux Val loop step appears after Step 10 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-create-ux/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 10 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

@test "AC5 placement: gaia-product-brief Val loop step appears after Step 8 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-product-brief/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 8 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

# ---------------------------------------------------------------------------
# Step renumbering invariants — keep vcp-cpt expectations and step counts
# in sync with the wire-in.
# ---------------------------------------------------------------------------

@test "step-count: gaia-create-prd has 14 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-create-prd/SKILL.md")
  [ "$count" = "14" ]
}

@test "step-count: gaia-create-ux has 12 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-create-ux/SKILL.md")
  [ "$count" = "12" ]
}

@test "step-count: gaia-product-brief has 9 Step headings after wire-in" {
  local count
  count=$(grep -cE '^### Step [0-9]+ —' "$SKILLS_DIR/gaia-product-brief/SKILL.md")
  [ "$count" = "9" ]
}

# ---------------------------------------------------------------------------
# Checkpoint emission — each new Val-loop step emits one
# write-checkpoint.sh invocation (E43-S2 wire-in convention).
# ---------------------------------------------------------------------------

@test "checkpoint: gaia-create-prd Val loop step emits one write-checkpoint.sh invocation at step 12" {
  grep -qE '^> `!(\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh gaia-create-prd 12 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-create-prd/SKILL.md"
}

@test "checkpoint: gaia-create-ux Val loop step emits one write-checkpoint.sh invocation at step 11" {
  grep -qE '^> `!(\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh gaia-create-ux 11 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-create-ux/SKILL.md"
}

@test "checkpoint: gaia-product-brief Val loop step emits one write-checkpoint.sh invocation at step 9" {
  grep -qE '^> `!(\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh gaia-product-brief 9 .*stage=val-auto-review' \
    "$SKILLS_DIR/gaia-product-brief/SKILL.md"
}
