#!/usr/bin/env bats
# e42-s1-brainstorm-checklist.bats — validates E42-S1 port of the V1
# /gaia-brainstorm 24-item checklist into V2 finalize.sh + SKILL.md.
#
# Covers VCP-CHK-01 (positive: all 24 items PASS) and VCP-CHK-02
# (negative: missing "At least 3 opportunity areas identified") per
# docs/test-artifacts/test-plan.md §11.46.1.
#
# The finalize.sh under test reads an optional BRAINSTORM_ARTIFACT env var
# so tests can point it at a fixture file rather than scanning
# docs/creative-artifacts/. The pre-existing checkpoint + lifecycle-event
# side effects must continue to succeed whether or not the checklist passes
# (story Dev Notes: "observability is not contingent on checklist pass").

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-brainstorm"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  # Isolate lifecycle-event writes too.
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-01 — Positive path: all 24 items satisfied.
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all script-verifiable items satisfied" {
  export BRAINSTORM_ARTIFACT="$FIXTURES/brainstorm-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist summary" {
  export BRAINSTORM_ARTIFACT="$FIXTURES/brainstorm-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist"* ]]
}

@test "finalize.sh reports PASS for opportunity-count item" {
  export BRAINSTORM_ARTIFACT="$FIXTURES/brainstorm-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"opportunity"* ]]
}

# -------------------------------------------------------------------------
# VCP-CHK-02 — Negative path: the "At least 3 opportunity areas identified"
# item is missing (only 2 present). Must fail with actionable guidance.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when opportunity areas < 3" {
  export BRAINSTORM_ARTIFACT="$FIXTURES/brainstorm-missing-opportunities.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names the failing item in its output" {
  export BRAINSTORM_ARTIFACT="$FIXTURES/brainstorm-missing-opportunities.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"opportunity"* ]]
  [[ "$output" == *"3"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export BRAINSTORM_ARTIFACT="$FIXTURES/brainstorm-missing-opportunities.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations"* ]]
}

# -------------------------------------------------------------------------
# AC3 / VCP-CHK-37 — Classification audit. Every item in the SKILL.md
# ## Validation section must carry a [script-verifiable] or [LLM-checkable]
# tag, and the count must be exactly 24.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 24 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "24" ]
}

@test "every Validation item is classified script-verifiable or LLM-checkable" {
  # Any bullet under ## Validation that is NOT classified would be a bug.
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- / && !/^- \[(script-verifiable|LLM-checkable)\]/ { bad++ }
    END { print bad + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# -------------------------------------------------------------------------
# Non-regression: checkpoint + lifecycle event still run on positive path.
# Observability must not be contingent on checklist outcome.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written on positive path" {
  export BRAINSTORM_ARTIFACT="$FIXTURES/brainstorm-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  # checkpoint.sh writes to $CHECKPOINT_PATH/<workflow>.yaml.
  [ -f "$CHECKPOINT_PATH/brainstorm-project.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-brainstorm.yaml" ]
}
