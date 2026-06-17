#!/usr/bin/env bats
# vcp-chk-24-infra-design-negative.bats — E42-S12 negative test for the
# V1 25-item /gaia-infra-design checklist ported to V2.
#
# Covers VCP-CHK-24 (negative) per docs/test-artifacts/test-plan.md and
# story AC2: given an infrastructure-design.md artifact missing the
# "State management strategy specified" V1 item, finalize.sh exits
# non-zero and names the V1 anchor verbatim in the violation list on
# stderr.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s12-infra-design"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-infra-design"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-24 — Negative: artifact missing the state-management item.
# V1 anchor "State management strategy specified" must appear verbatim
# in violation output.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when state-management item is missing" {
  export INFRA_DESIGN_ARTIFACT="$FIXTURES/infrastructure-design-missing-state.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the State management strategy item in failure output" {
  export INFRA_DESIGN_ARTIFACT="$FIXTURES/infrastructure-design-missing-state.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"State management strategy specified"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export INFRA_DESIGN_ARTIFACT="$FIXTURES/infrastructure-design-missing-state.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-infra-design" {
  export INFRA_DESIGN_ARTIFACT="$FIXTURES/infrastructure-design-missing-state.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"infra-design"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still succeed on
# the negative path. Observability must run regardless.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export INFRA_DESIGN_ARTIFACT="$FIXTURES/infrastructure-design-missing-state.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/infrastructure-design.yaml" ] \
    || [ -f "$CHECKPOINT_PATH/gaia-infra-design.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — INFRA_DESIGN_ARTIFACT points at a missing file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when INFRA_DESIGN_ARTIFACT points at a missing file" {
  export INFRA_DESIGN_ARTIFACT="$BATS_TMPDIR/does-not-exist-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

# -------------------------------------------------------------------------
# AC-EC1 — INFRA_DESIGN_ARTIFACT points at an empty (0-byte) file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when the artifact is 0 bytes" {
  local empty
  empty="$TEST_TMP/empty-infra-design.md"
  : > "$empty"
  [ -f "$empty" ]
  [ ! -s "$empty" ]
  export INFRA_DESIGN_ARTIFACT="$empty"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}
