#!/usr/bin/env bats
# vcp-chk-06-domain-research-negative.bats — E42-S3 negative test for
# the V1 22-item /gaia-domain-research checklist ported to V2.
#
# Covers VCP-CHK-06 (negative) per docs/test-artifacts/test-plan.md
# §11.46.1 and story AC2: given an artifact missing the
# "Terminology Glossary" section, finalize.sh exits non-zero and names
# the specific failing item in the violation list printed to stderr.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-domain-research"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-06 — Negative: Terminology Glossary missing.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when Terminology Glossary missing" {
  export DOMAIN_RESEARCH_ARTIFACT="$FIXTURES/domain-research-missing-glossary.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the Terminology Glossary in the failure output" {
  export DOMAIN_RESEARCH_ARTIFACT="$FIXTURES/domain-research-missing-glossary.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Terminology Glossary"* ]] || [[ "$output" == *"glossary"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export DOMAIN_RESEARCH_ARTIFACT="$FIXTURES/domain-research-missing-glossary.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

@test "finalize.sh guides user back to /gaia-domain-research" {
  export DOMAIN_RESEARCH_ARTIFACT="$FIXTURES/domain-research-missing-glossary.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"domain-research"* ]]
}

# -------------------------------------------------------------------------
# Non-regression: checkpoint + lifecycle event still succeed on the
# negative path. Observability must run regardless of checklist.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written even when checklist fails" {
  export DOMAIN_RESEARCH_ARTIFACT="$FIXTURES/domain-research-missing-glossary.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/domain-research.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-domain-research.yaml" ]
}
