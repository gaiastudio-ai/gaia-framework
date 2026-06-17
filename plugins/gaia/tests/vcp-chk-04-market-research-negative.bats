#!/usr/bin/env bats
# vcp-chk-04-market-research-negative.bats — E42-S2 negative test for
# the V1 28-item /gaia-market-research checklist ported to V2.
#
# Covers VCP-CHK-04 (negative) per docs/test-artifacts/test-plan.md
# §11.46.1 and story AC2: given an artifact missing the
# "TAM/SAM/SOM estimates provided with assumptions" rule, finalize.sh
# exits non-zero and names the specific failing item in the violation
# list printed to stderr.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-market-research"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-04 — Negative: TAM/SAM/SOM assumptions missing.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when TAM/SAM/SOM assumptions missing" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-missing-tam-assumptions.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names assumptions in the failure output" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-missing-tam-assumptions.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"assumptions"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-missing-tam-assumptions.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-market-research" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-missing-tam-assumptions.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"market-research"* ]]
}

# -------------------------------------------------------------------------
# Non-regression: checkpoint + lifecycle event still succeed on the
# negative path. Observability must run regardless of checklist.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export MARKET_RESEARCH_ARTIFACT="$FIXTURES/market-research-missing-tam-assumptions.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/market-research.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-market-research.yaml" ]
}
