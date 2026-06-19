#!/usr/bin/env bats
# vcp-chk-22-threat-model-negative.bats — E42-S11 negative test for the
# V1 25-item /gaia-threat-model checklist ported to V2.
#
# Covers VCP-CHK-22 (negative) per docs/test-artifacts/test-plan.md and
# story AC2: given a threat-model.md artifact with one component
# missing the Repudiation STRIDE category, finalize.sh exits non-zero
# and names the V1 anchor "All six STRIDE categories evaluated per
# component" verbatim in the violation list on stderr.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s11-threat-model"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-threat-model"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-22 — Negative: one component missing STRIDE Repudiation row.
# V1 anchor "All six STRIDE categories evaluated per component" must
# appear verbatim in violation output.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when a STRIDE category is missing for a component" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-missing-stride.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the All six STRIDE categories item in failure output" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-missing-stride.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"All six STRIDE categories evaluated per component"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-missing-stride.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-threat-model" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-missing-stride.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"threat-model"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still succeed on
# the negative path. Observability must run regardless.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export THREAT_MODEL_ARTIFACT="$FIXTURES/threat-model-missing-stride.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/security-threat-model.yaml" ] \
    || [ -f "$CHECKPOINT_PATH/gaia-threat-model.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — THREAT_MODEL_ARTIFACT points at a missing file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when THREAT_MODEL_ARTIFACT points at a missing file" {
  export THREAT_MODEL_ARTIFACT="$BATS_TMPDIR/does-not-exist-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

# -------------------------------------------------------------------------
# AC-EC1 — THREAT_MODEL_ARTIFACT points at an empty (0-byte) file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when the artifact is 0 bytes" {
  local empty
  empty="$TEST_TMP/empty-threat-model.md"
  : > "$empty"
  [ -f "$empty" ]
  [ ! -s "$empty" ]
  export THREAT_MODEL_ARTIFACT="$empty"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}
