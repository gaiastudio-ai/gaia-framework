#!/usr/bin/env bats
# vcp-chk-20-create-epics-negative.bats — E42-S10 negative test for the
# V1 31-item /gaia-create-epics checklist ported to V2.
#
# Covers VCP-CHK-20 (negative) per docs/test-artifacts/test-plan.md
# and story AC2: given an epics-and-stories.md artifact with a
# circular dependency E1-S1 → E1-S2 → E1-S1, finalize.sh exits
# non-zero and names the V1 anchor "No circular dependencies"
# verbatim in the violation list on stderr. Story ACs: AC2, AC4.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
UPSTREAM="$BATS_TEST_DIRNAME/fixtures/e42-s10-upstream"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-epics"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
  export TEST_PLAN_PATH="$UPSTREAM/test-plan.md"
  export ARCHITECTURE_PATH="$UPSTREAM/architecture.md"
  export PRD_PATH="$UPSTREAM/prd.md"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-20 — Negative: circular dependency E1-S1 ↔ E1-S2.
# V1 anchor "No circular dependencies" must appear verbatim in violation
# output.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when a cycle is present" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-cycle.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the No circular dependencies item in failure output" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-cycle.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No circular dependencies"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-cycle.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-create-epics" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-cycle.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"create-epics"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still succeed on
# the negative path. Observability must run regardless.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-cycle.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/create-epics-stories.yaml" ] \
    || [ -f "$CHECKPOINT_PATH/gaia-create-epics.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — EPICS_ARTIFACT points at a missing file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when EPICS_ARTIFACT points at a missing file" {
  export EPICS_ARTIFACT="$BATS_TMPDIR/does-not-exist-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

# -------------------------------------------------------------------------
# AC-EC1 — EPICS_ARTIFACT points at an empty (0-byte) file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when the artifact is 0 bytes" {
  local empty
  empty="$TEST_TMP/empty-epics.md"
  : > "$empty"
  [ -f "$empty" ]
  [ ! -s "$empty" ]
  export EPICS_ARTIFACT="$empty"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}
