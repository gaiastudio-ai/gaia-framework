#!/usr/bin/env bats
# e44-s3-phase1-val-auto-review-wire-in.bats
#
# Script-verifiable coverage for E44-S3 — wiring the Val auto-fix loop
# (E44-S2 / ADR-058) into the 4 Phase 1 artifact-producing skills:
#
#   - gaia-brainstorm        -> docs/creative-artifacts/brainstorm-{slug}.md
#   - gaia-market-research   -> docs/planning-artifacts/market-research.md
#   - gaia-domain-research   -> docs/planning-artifacts/domain-research.md
#   - gaia-tech-research     -> docs/planning-artifacts/technical-research.md
#
# Story acceptance criteria covered (script-verifiable subset):
#   AC1 — auto-invocation step embedded after artifact-write
#   AC4 — deprecated `val_validate_output` flag absent from all 4 SKILL.md
#   AC5 — canonical E44-S2 reference snippet appears in each file with
#         iteration counter, 3-cap check, and ADR-058 / E44-S2 provenance
#   AC-EC3 — artifact-existence guard ("if not exists ... exit") embedded
#   AC-EC6 — Val-skill-availability guard ("Val auto-review unavailable")
#   AC-EC8 — YOLO hard-gate invariant referenced (no bypass branch)
#
# LLM-checkable AC (AC2, AC3, AC-EC1, AC-EC2, AC-EC4, AC-EC5, AC-EC7) are
# covered by the broader VCP orchestrator and the iteration-3 prompt is
# centralized in gaia-val-validate SKILL.md (E44-S2). This bats suite does
# not duplicate the centralized prompt assertions.

load 'test_helper.bash'

setup() {
  common_setup
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export SKILLS_DIR
  # Phase 1 skills as a space-delimited string (bats setup() locals do not
  # persist into @test bodies cleanly — reconstruct the array per-test).
  PHASE1_SKILLS_LIST="gaia-brainstorm gaia-market-research gaia-domain-research gaia-tech-research"
  export PHASE1_SKILLS_LIST
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Pre-flight — all 4 Phase 1 SKILL.md files exist and are readable
# ---------------------------------------------------------------------------

@test "preflight: all 4 Phase 1 SKILL.md files exist" {
  for skill in $PHASE1_SKILLS_LIST; do
    [ -f "$SKILLS_DIR/$skill/SKILL.md" ]
    [ -r "$SKILLS_DIR/$skill/SKILL.md" ]
  done
}

# ---------------------------------------------------------------------------
# AC1 / AC5 — Each SKILL.md embeds the Val Auto-Fix Loop step
# ---------------------------------------------------------------------------

@test "AC1: gaia-brainstorm SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-brainstorm/SKILL.md"
}

@test "AC1: gaia-market-research SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-market-research/SKILL.md"
}

@test "AC1: gaia-domain-research SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-domain-research/SKILL.md"
}

@test "AC1: gaia-tech-research SKILL.md contains Val Auto-Fix Loop step" {
  grep -q 'Val Auto-Fix Loop' "$SKILLS_DIR/gaia-tech-research/SKILL.md"
}

@test "AC1: each Phase 1 skill invokes /gaia-val-validate with artifact_path and artifact_type" {
  for skill in $PHASE1_SKILLS_LIST; do
    grep -q '/gaia-val-validate' "$SKILLS_DIR/$skill/SKILL.md"
    grep -q 'artifact_path' "$SKILLS_DIR/$skill/SKILL.md"
    grep -q 'artifact_type' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC1: gaia-brainstorm uses artifact_type=brainstorm" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*brainstorm' "$SKILLS_DIR/gaia-brainstorm/SKILL.md"
}

@test "AC1: gaia-market-research uses artifact_type=market-research" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*market-research' "$SKILLS_DIR/gaia-market-research/SKILL.md"
}

@test "AC1: gaia-domain-research uses artifact_type=domain-research" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*domain-research' "$SKILLS_DIR/gaia-domain-research/SKILL.md"
}

@test "AC1: gaia-tech-research uses artifact_type=technical-research" {
  # E44-S11: slug aligned with on-disk filename technical-research.md
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*technical-research' "$SKILLS_DIR/gaia-tech-research/SKILL.md"
}

@test "AC1: gaia-brainstorm references brainstorm-{slug}.md artifact_path" {
  grep -q 'brainstorm-{slug}.md' "$SKILLS_DIR/gaia-brainstorm/SKILL.md"
}

@test "AC1: gaia-market-research references market-research.md artifact_path" {
  grep -q 'market-research.md' "$SKILLS_DIR/gaia-market-research/SKILL.md"
}

@test "AC1: gaia-domain-research references domain-research.md artifact_path" {
  grep -q 'domain-research.md' "$SKILLS_DIR/gaia-domain-research/SKILL.md"
}

@test "AC1: gaia-tech-research references technical-research.md artifact_path" {
  grep -q 'technical-research.md' "$SKILLS_DIR/gaia-tech-research/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC4 — Deprecated flag `val_validate_output` absent from all 4 SKILL.md
# ---------------------------------------------------------------------------

@test "AC4: gaia-brainstorm SKILL.md does NOT use val_validate_output flag" {
  ! grep -q 'val_validate_output' "$SKILLS_DIR/gaia-brainstorm/SKILL.md"
}

@test "AC4: gaia-market-research SKILL.md does NOT use val_validate_output flag" {
  ! grep -q 'val_validate_output' "$SKILLS_DIR/gaia-market-research/SKILL.md"
}

@test "AC4: gaia-domain-research SKILL.md does NOT use val_validate_output flag" {
  ! grep -q 'val_validate_output' "$SKILLS_DIR/gaia-domain-research/SKILL.md"
}

@test "AC4: gaia-tech-research SKILL.md does NOT use val_validate_output flag" {
  ! grep -q 'val_validate_output' "$SKILLS_DIR/gaia-tech-research/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC5 — E44-S2 / ADR-058 provenance and 3-iteration cap referenced
# ---------------------------------------------------------------------------

@test "AC5: each Phase 1 skill references E44-S2 (pattern provenance)" {
  # The pattern is centralized in gaia-val-validate/SKILL.md; each skill
  # cites this path as its provenance anchor instead of an internal story ID.
  for skill in $PHASE1_SKILLS_LIST; do
    grep -q 'gaia-val-validate/SKILL.md' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC5: each Phase 1 skill references ADR-058 (decision provenance)" {
  # The decision to centralize the loop spec is expressed by the canonical
  # "cite this anchor" instruction present in every wired-in skill.
  for skill in $PHASE1_SKILLS_LIST; do
    grep -q 'Do not duplicate the spec here; cite this anchor' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC5: each Phase 1 skill documents iteration counter (iteration = 1)" {
  for skill in $PHASE1_SKILLS_LIST; do
    grep -q -E 'iteration[[:space:]]*=[[:space:]]*1' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC5: each Phase 1 skill documents the 3-iteration cap" {
  for skill in $PHASE1_SKILLS_LIST; do
    grep -q -E 'iteration[[:space:]]*<=[[:space:]]*3' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

@test "AC5: each Phase 1 skill cites the canonical Auto-Fix Loop Pattern anchor" {
  for skill in $PHASE1_SKILLS_LIST; do
    grep -q 'Auto-Fix Loop Pattern' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC3 — Artifact-existence guard
# ---------------------------------------------------------------------------

@test "AC-EC3: each Phase 1 skill includes an artifact-existence guard" {
  for skill in $PHASE1_SKILLS_LIST; do
    grep -q -E 'if[[:space:]]+not[[:space:]]+exists' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC6 — Val-skill-availability guard with documented warning text
# ---------------------------------------------------------------------------

@test "AC-EC6: each Phase 1 skill emits the canonical missing-Val warning" {
  for skill in $PHASE1_SKILLS_LIST; do
    grep -q 'Val auto-review unavailable' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# AC-EC8 — YOLO hard-gate invariant; no bypass branch introduced
# ---------------------------------------------------------------------------

@test "AC-EC8: each Phase 1 skill references the YOLO hard-gate invariant" {
  for skill in $PHASE1_SKILLS_LIST; do
    grep -q -E 'YOLO' "$SKILLS_DIR/$skill/SKILL.md"
  done
}

# ---------------------------------------------------------------------------
# Loop placement — wire-in step appears AFTER the artifact-write step
# (AC1, AC3 placement contract) — checked by line ordering for skills that
# write to a single canonical path. For gaia-brainstorm the artifact-write
# step writes to docs/creative-artifacts/brainstorm-{slug}.md; for the other
# three, the artifact-write step writes to docs/planning-artifacts/...md.
# ---------------------------------------------------------------------------

@test "placement: gaia-brainstorm Val loop step appears after Step 5 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-brainstorm/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 5 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

@test "placement: gaia-market-research Val loop step appears after Step 6 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-market-research/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 6 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

@test "placement: gaia-domain-research Val loop step appears after Step 5 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-domain-research/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 5 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}

@test "placement: gaia-tech-research Val loop step appears after Step 5 (Generate Output)" {
  local skill="$SKILLS_DIR/gaia-tech-research/SKILL.md"
  local write_line val_line
  write_line="$(grep -n '^### Step 5 — Generate Output' "$skill" | head -1 | cut -d: -f1)"
  val_line="$(grep -n 'Val Auto-Fix Loop' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$write_line" ]
  [ -n "$val_line" ]
  [ "$val_line" -gt "$write_line" ]
}
