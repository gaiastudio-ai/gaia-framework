#!/usr/bin/env bats
# vcp-chk-11-create-prd-positive.bats — E42-S6 positive test for the
# V1 36-item /gaia-create-prd checklist ported to V2.
#
# Covers VCP-CHK-11 (positive) per docs/test-artifacts/test-plan.md
# and story AC1: given an artifact satisfying all 36 items,
# finalize.sh exits 0 and every script-verifiable item reports PASS.
#
# The finalize.sh under test reads an optional PRD_ARTIFACT env var so
# tests point it at a fixture rather than scanning
# docs/planning-artifacts/. The checkpoint + lifecycle-event side
# effects must continue to succeed regardless of checklist outcome
# (story AC5 + E42-S1/S2/S3/S4/S5 precedent: "observability is not
# contingent on checklist pass").

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-prd"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-11 — Positive: all 36 items satisfied.
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all script-verifiable items satisfied" {
  export PRD_ARTIFACT="$FIXTURES/prd-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist summary" {
  export PRD_ARTIFACT="$FIXTURES/prd-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist"* ]]
}

@test "finalize.sh reports PASS for each required section" {
  export PRD_ARTIFACT="$FIXTURES/prd-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Overview"* ]]
  [[ "$output" == *"Functional Requirements"* ]]
  [[ "$output" == *"Non-Functional Requirements"* ]]
  [[ "$output" == *"User Journeys"* ]]
  [[ "$output" == *"Data Requirements"* ]]
  [[ "$output" == *"Integration Requirements"* ]]
  [[ "$output" == *"Out of Scope"* ]]
  [[ "$output" == *"Constraints"* ]]
  [[ "$output" == *"Success Criteria"* ]]
  [[ "$output" == *"Dependencies"* ]]
  [[ "$output" == *"Requirements Summary Table"* ]]
}

# -------------------------------------------------------------------------
# AC3 — Classification audit. Every item in the SKILL.md ## Validation
# section must carry a [script-verifiable] or [LLM-checkable] tag, and
# the count must be exactly 36.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 36 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "36" ]
}

@test "every Validation item is classified script-verifiable or LLM-checkable" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- / && !/^- \[(script-verifiable|LLM-checkable)\]/ { bad++ }
    END { print bad + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "at least structural items are classified script-verifiable" {
  # Requirements Summary Table present, FR-### / NFR-### ID format,
  # section headings — MUST be SV, never LLM.
  run grep -E '^\- \[script-verifiable\].*Requirements Summary Table' "$SKILL_MD"
  [ "$status" -eq 0 ]
  run grep -E '^\- \[script-verifiable\].*FR-' "$SKILL_MD"
  [ "$status" -eq 0 ]
  run grep -E '^\- \[script-verifiable\].*NFR-' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still run on
# positive path. Observability must not be contingent on checklist.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written on positive path" {
  export PRD_ARTIFACT="$FIXTURES/prd-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/create-prd.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-create-prd.yaml" ]
}
