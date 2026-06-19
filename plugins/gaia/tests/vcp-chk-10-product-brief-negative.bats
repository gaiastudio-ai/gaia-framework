#!/usr/bin/env bats
# vcp-chk-10-product-brief-negative.bats — E42-S5 negative test for
# the V1 27-item /gaia-product-brief checklist ported to V2.
#
# Covers VCP-CHK-10 (negative) per docs/test-artifacts/test-plan.md
# and story AC2: given an artifact missing a required section
# (e.g., Vision Statement), finalize.sh exits non-zero and names the
# failing item by its exact V1 string in the violation list on stderr.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-product-brief"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-10 — Negative: Vision Statement section stripped.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when Vision Statement section missing" {
  export PRODUCT_BRIEF_ARTIFACT="$FIXTURES/product-brief-missing-vision.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the Vision Statement item in the failure output" {
  export PRODUCT_BRIEF_ARTIFACT="$FIXTURES/product-brief-missing-vision.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Vision Statement"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export PRODUCT_BRIEF_ARTIFACT="$FIXTURES/product-brief-missing-vision.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-product-brief" {
  export PRODUCT_BRIEF_ARTIFACT="$FIXTURES/product-brief-missing-vision.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"product-brief"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still succeed on
# the negative path. Observability must run regardless of checklist.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export PRODUCT_BRIEF_ARTIFACT="$FIXTURES/product-brief-missing-vision.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/create-product-brief.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-product-brief.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — No artifact present. Mirrors E42-S4: PRODUCT_BRIEF_ARTIFACT set
# to a missing file triggers the AC4 missing-artifact violation path.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when PRODUCT_BRIEF_ARTIFACT points at a missing file" {
  export PRODUCT_BRIEF_ARTIFACT="$BATS_TMPDIR/does-not-exist-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}
