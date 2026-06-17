#!/usr/bin/env bats
# vcp-chk-12-create-prd-negative.bats — E42-S6 negative test for the
# V1 36-item /gaia-create-prd checklist ported to V2.
#
# Covers VCP-CHK-12 (negative) per docs/test-artifacts/test-plan.md
# and story AC4: given a PRD with dependencies listed but no
# failure-mode / fallback-behavior text, finalize.sh exits non-zero
# and names the failing item by its exact V1 string in the violation
# list on stderr. Story ACs: AC2, AC4, AC-EC9.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-prd"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-12 — Negative: Dependencies section lacks failure-mode /
# fallback-behavior coverage.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when dep failure modes missing" {
  export PRD_ARTIFACT="$FIXTURES/prd-missing-deps-failure-modes.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the Critical dependencies item in the failure output" {
  export PRD_ARTIFACT="$FIXTURES/prd-missing-deps-failure-modes.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failure modes"* ]]
  [[ "$output" == *"fallback"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export PRD_ARTIFACT="$FIXTURES/prd-missing-deps-failure-modes.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-create-prd" {
  export PRD_ARTIFACT="$FIXTURES/prd-missing-deps-failure-modes.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"create-prd"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5 / AC-EC6): checkpoint + lifecycle event still
# succeed on the negative path. Observability must run regardless.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export PRD_ARTIFACT="$FIXTURES/prd-missing-deps-failure-modes.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/create-prd.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-create-prd.yaml" ]
}

# -------------------------------------------------------------------------
# AC-EC3 — PRD_ARTIFACT points at a missing file. Mirrors E42-S5 AC4.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when PRD_ARTIFACT points at a missing file" {
  export PRD_ARTIFACT="$BATS_TMPDIR/does-not-exist-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}
