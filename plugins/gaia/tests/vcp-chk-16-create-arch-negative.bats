#!/usr/bin/env bats
# vcp-chk-16-create-arch-negative.bats — E42-S8 negative test for the
# V1 33-item /gaia-create-arch checklist ported to V2.
#
# Covers VCP-CHK-16 (negative) per docs/test-artifacts/test-plan.md
# and story AC2 / AC-EC5: given an architecture artifact with the
# Decision Log heading but no ADR rows in the table, finalize.sh exits
# non-zero and names the failing item verbatim ("Decisions recorded" is
# the V1 anchor) in the violation list on stderr. Story ACs: AC2, AC4,
# AC-EC5.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-arch"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-16 — Negative: Decision Log table empty (heading only).
# V1 anchor "Decisions recorded" must appear verbatim.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when Decision Log table empty" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-missing-adrs.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the Decisions recorded item in the failure output" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-missing-adrs.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Decisions recorded"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-missing-adrs.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-create-arch" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-missing-adrs.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"create-arch"* ]] || [[ "$output" == *"create-architecture"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still succeed on
# the negative path. Observability must run regardless.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-missing-adrs.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/create-architecture.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-create-arch.yaml" ]
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
