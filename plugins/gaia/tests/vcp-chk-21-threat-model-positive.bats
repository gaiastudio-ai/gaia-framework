#!/usr/bin/env bats
# vcp-chk-21-threat-model-positive.bats — E42-S11 positive test for the
# V1 25-item /gaia-threat-model checklist ported to V2.
#
# Covers VCP-CHK-21 (positive) per docs/test-artifacts/test-plan.md and
# story AC1: given a threat-model.md artifact satisfying all 25 items,
# finalize.sh exits 0 and every script-verifiable item reports PASS.
#
# The finalize.sh under test reads THREAT_MODEL_ARTIFACT (fixture path)
# so tests point at per-test fixtures rather than scanning the repo
# working tree. Checkpoint + lifecycle-event side effects continue to
# succeed regardless of checklist outcome (story AC5 + E42-S1..S10
# precedent).

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s11-threat-model"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-threat-model"
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
# VCP-CHK-21 — Positive: all 25 items satisfied.
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all script-verifiable items satisfied" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist summary" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist"* ]]
}

@test "finalize.sh reports PASS for All six STRIDE categories" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All six STRIDE categories evaluated per component"* ]]
}

@test "finalize.sh reports PASS for Each threat scored on all 5 DREAD dimensions" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Each threat scored on all 5 DREAD dimensions"* ]]
}

@test "finalize.sh reports 15 script-verifiable PASS items" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"15/15 script-verifiable items PASS"* ]]
}

# -------------------------------------------------------------------------
# AC3 — Classification audit. Every item in the SKILL.md ## Validation
# section must carry a [script-verifiable] or [LLM-checkable] tag, and
# the count must be exactly 25.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 25 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "25" ]
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

@test "STRIDE per-component check is classified script-verifiable" {
  # Per epic design: "All six STRIDE categories evaluated per
  # component" MUST land on script-verifiable (structural check).
  run grep -E '^\- \[script-verifiable\].*(All six STRIDE|STRIDE categories evaluated)' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "SKILL.md ## Validation sits between ## Steps and ## Finalize" {
  run awk '
    /^## Steps/      { steps = NR }
    /^## Validation/ { validation = NR }
    /^## Finalize/   { finalize = NR }
    END {
      if (steps > 0 && validation > 0 && finalize > 0 \
          && validation > steps && validation < finalize) { print "ok" }
      else { print "bad" }
    }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still run on
# positive path. Observability must not be contingent on checklist.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written on positive path" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/security-threat-model.yaml" ] \
    || [ -f "$CHECKPOINT_PATH/gaia-threat-model.yaml" ]
}

# -------------------------------------------------------------------------
# WORKFLOW_NAME integrity — prior Val finding: MUST remain
# "security-threat-model" (not "threat-model").
# -------------------------------------------------------------------------

@test "Val-finding: WORKFLOW_NAME in finalize.sh is security-threat-model" {
  run grep -E '^WORKFLOW_NAME="security-threat-model"' "$FINALIZE"
  [ "$status" -eq 0 ]
}
