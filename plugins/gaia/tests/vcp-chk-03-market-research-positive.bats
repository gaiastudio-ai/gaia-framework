#!/usr/bin/env bats
# vcp-chk-03-market-research-positive.bats — E42-S2 positive test for
# the V1 28-item /gaia-market-research checklist ported to V2.
#
# Covers VCP-CHK-03 (positive) per docs/test-artifacts/test-plan.md
# §11.46.1 and story AC1: given an artifact satisfying all 28 items,
# finalize.sh exits 0 and every script-verifiable item reports PASS.
#
# The finalize.sh under test reads an optional MARKET_RESEARCH_ARTIFACT
# env var so tests point it at a fixture rather than scanning
# docs/planning-artifacts/. The checkpoint + lifecycle-event side
# effects must continue to succeed regardless of checklist outcome
# (story Dev Notes: "observability is not contingent on checklist
# pass").

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-market-research"
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
# VCP-CHK-03 — Positive: all 28 items satisfied.
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all script-verifiable items satisfied" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist summary" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist"* ]]
}

@test "finalize.sh reports PASS for the competitor-count item" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"competitor"* ]]
}

@test "finalize.sh reports PASS for TAM/SAM/SOM estimate items" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TAM"* ]]
  [[ "$output" == *"SAM"* ]]
  [[ "$output" == *"SOM"* ]]
}

# -------------------------------------------------------------------------
# AC3 / VCP-CHK-37 slice — Classification audit. Every item in the
# SKILL.md ## Validation section must carry a [script-verifiable] or
# [LLM-checkable] tag, and the count must be exactly 28.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 28 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "28" ]
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
# Non-regression: checkpoint + lifecycle event still run on positive
# path. Observability must not be contingent on checklist outcome.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written on positive path" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/market-research.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-market-research.yaml" ]
}
