#!/usr/bin/env bats
# vcp-chk-14-create-ux-negative.bats — E42-S7 negative test for the
# V1 26-item /gaia-create-ux checklist ported to V2.
#
# Covers VCP-CHK-14 (negative) per docs/test-artifacts/test-plan.md
# and story AC2 / AC4: given a UX design artifact missing the
# Wireframes body (V1 anchor "Key screens described"), finalize.sh
# exits non-zero and names the failing item verbatim in the violation
# list on stderr. Story ACs: AC2, AC4.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-ux"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-14 — Negative: Wireframes section body empty. The V1 source
# item "Key screens described" is the anchor — that string must appear
# in the violation output verbatim.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when Wireframes body empty" {
  export UX_DESIGN_ARTIFACT="$FIXTURES/ux-design-missing-wireframes.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the Key screens described item in the failure output" {
  export UX_DESIGN_ARTIFACT="$FIXTURES/ux-design-missing-wireframes.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Key screens described"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export UX_DESIGN_ARTIFACT="$FIXTURES/ux-design-missing-wireframes.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-create-ux" {
  export UX_DESIGN_ARTIFACT="$FIXTURES/ux-design-missing-wireframes.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"create-ux"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still succeed on
# the negative path. Observability must run regardless.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export UX_DESIGN_ARTIFACT="$FIXTURES/ux-design-missing-wireframes.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/create-ux.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-create-ux.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — UX_DESIGN_ARTIFACT points at a missing file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when UX_DESIGN_ARTIFACT points at a missing file" {
  export UX_DESIGN_ARTIFACT="$BATS_TMPDIR/does-not-exist-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}
