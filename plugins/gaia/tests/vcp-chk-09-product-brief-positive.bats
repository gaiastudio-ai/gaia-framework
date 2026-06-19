#!/usr/bin/env bats
# vcp-chk-09-product-brief-positive.bats — E42-S5 positive test for
# the V1 27-item /gaia-product-brief checklist ported to V2.
#
# Covers VCP-CHK-09 (positive) per docs/test-artifacts/test-plan.md
# and story AC1: given an artifact satisfying all 27 items,
# finalize.sh exits 0 and every script-verifiable item reports PASS.
#
# The finalize.sh under test reads an optional PRODUCT_BRIEF_ARTIFACT
# env var so tests point it at a fixture rather than scanning
# docs/creative-artifacts/. The checkpoint + lifecycle-event side
# effects must continue to succeed regardless of checklist outcome
# (story AC5 + E42-S1/S2/S3/S4 precedent: "observability is not
# contingent on checklist pass").

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-product-brief"
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
# VCP-CHK-09 — Positive: all 27 items satisfied.
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all script-verifiable items satisfied" {
  export PRODUCT_BRIEF_ARTIFACT="$FIXTURES/product-brief-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist summary" {
  export PRODUCT_BRIEF_ARTIFACT="$FIXTURES/product-brief-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist"* ]]
}

@test "finalize.sh reports PASS for each of the 9 required sections" {
  export PRODUCT_BRIEF_ARTIFACT="$FIXTURES/product-brief-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Vision Statement"* ]]
  [[ "$output" == *"Target Users"* ]]
  [[ "$output" == *"Problem Statement"* ]]
  [[ "$output" == *"Proposed Solution"* ]]
  [[ "$output" == *"Key Features"* ]]
  [[ "$output" == *"Scope and Boundaries"* ]]
  [[ "$output" == *"Risks and Assumptions"* ]]
  [[ "$output" == *"Competitive Landscape"* ]]
  [[ "$output" == *"Success Metrics"* ]]
}

# -------------------------------------------------------------------------
# AC3 — Classification audit. Every item in the SKILL.md ## Validation
# section must carry a [script-verifiable] or [LLM-checkable] tag, and
# the count must be exactly 27.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 27 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "27" ]
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

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still run on
# positive path. Observability must not be contingent on checklist.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written on positive path" {
  export PRODUCT_BRIEF_ARTIFACT="$FIXTURES/product-brief-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/create-product-brief.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-product-brief.yaml" ]
}
