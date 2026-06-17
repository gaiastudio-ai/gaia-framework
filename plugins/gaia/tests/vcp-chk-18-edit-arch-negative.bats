#!/usr/bin/env bats
# vcp-chk-18-edit-arch-negative.bats — E42-S9 negative test for the
# V1 25-item /gaia-edit-arch checklist ported to V2.
#
# Covers VCP-CHK-18 (negative) per docs/test-artifacts/test-plan.md
# and story AC2: given an architecture artifact with the Version History
# section missing, finalize.sh exits non-zero and names the failing item
# verbatim ("Version History" is the V1 anchor) in the violation list on
# stderr. Story ACs: AC2, AC4.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-edit-arch"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-18 — Negative: Version History section missing.
# V1 anchor "Version History" must appear verbatim in violation output.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when Version History missing" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-missing-version-history.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the Version History item in failure output" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-missing-version-history.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Version History"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-missing-version-history.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-edit-arch" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-missing-version-history.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"edit-arch"* ]] || [[ "$output" == *"edit-architecture"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still succeed on
# the negative path. Observability must run regardless.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-missing-version-history.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/edit-architecture.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-edit-arch.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — ARCHITECTURE_ARTIFACT points at a missing file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when ARCHITECTURE_ARTIFACT points at a missing file" {
  export ARCHITECTURE_ARTIFACT="$BATS_TMPDIR/does-not-exist-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}
