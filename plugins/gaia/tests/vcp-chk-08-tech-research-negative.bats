#!/usr/bin/env bats
# vcp-chk-08-tech-research-negative.bats — E42-S4 negative test for
# the V1 22-item /gaia-tech-research checklist ported to V2.
#
# Covers VCP-CHK-08 (negative) per docs/test-artifacts/test-plan.md
# and story AC2: given an artifact missing the
# "At least 2 alternatives compared" V1 rule, finalize.sh exits
# non-zero and names the failing item in the violation list on stderr.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-tech-research"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-08 — Negative: "At least 2 alternatives compared" missing.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when only 1 alternative present" {
  export TECH_RESEARCH_ARTIFACT="$FIXTURES/tech-research-missing-alternatives.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the alternatives item in the failure output" {
  export TECH_RESEARCH_ARTIFACT="$FIXTURES/tech-research-missing-alternatives.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alternatives"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export TECH_RESEARCH_ARTIFACT="$FIXTURES/tech-research-missing-alternatives.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-tech-research" {
  export TECH_RESEARCH_ARTIFACT="$FIXTURES/tech-research-missing-alternatives.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tech-research"* ]]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still succeed on
# the negative path. Observability must run regardless of checklist.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export TECH_RESEARCH_ARTIFACT="$FIXTURES/tech-research-missing-alternatives.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/technical-research.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-tech-research.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — No artifact present. Regression from E42-S1/S2/S3: legacy
# finalize.sh returned 0 here. Story Dev Notes reiterate observability
# must continue; tech-research story AC4 explicitly says a missing
# artifact should surface a violation. We align with AC4 by treating
# an unset artifact as "skip checklist" (exit 0) only when the caller
# explicitly acknowledges no artifact. TECH_RESEARCH_ARTIFACT set to
# a missing file triggers the AC4 missing-artifact violation path.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when TECH_RESEARCH_ARTIFACT points at a missing file" {
  export TECH_RESEARCH_ARTIFACT="$BATS_TMPDIR/does-not-exist-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}
