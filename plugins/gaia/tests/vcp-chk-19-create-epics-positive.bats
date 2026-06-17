#!/usr/bin/env bats
# vcp-chk-19-create-epics-positive.bats — E42-S10 positive test for the
# V1 31-item /gaia-create-epics checklist ported to V2.
#
# Covers VCP-CHK-19 (positive) per docs/test-artifacts/test-plan.md
# and story AC1: given an epics-and-stories.md artifact satisfying all
# 31 items, finalize.sh exits 0 and every script-verifiable item reports
# PASS.
#
# The finalize.sh under test reads EPICS_ARTIFACT (fixture path),
# TEST_PLAN_PATH, ARCHITECTURE_PATH, and PRD_PATH env vars so tests
# point at per-test fixtures rather than scanning the repo working
# tree. Checkpoint + lifecycle-event side effects continue to succeed
# regardless of checklist outcome (story AC5 + E42-S1..S9 precedent).

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
UPSTREAM="$BATS_TEST_DIRNAME/fixtures/e42-s10-upstream"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-epics"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"

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
# VCP-CHK-19 — Positive: all 31 items satisfied.
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all script-verifiable items satisfied" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist summary" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist"* ]]
}

@test "finalize.sh reports PASS for No circular dependencies" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No circular dependencies"* ]]
}

@test "finalize.sh reports PASS for test-plan.md read and risk levels extracted" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-plan.md read and risk levels extracted"* ]]
}

@test "finalize.sh reports 21 script-verifiable PASS items" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"21/21 script-verifiable items PASS"* ]]
}

# -------------------------------------------------------------------------
# AC3 — Classification audit. Every item in the SKILL.md ## Validation
# section must carry a [script-verifiable] or [LLM-checkable] tag, and
# the count must be exactly 31.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 31 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "31" ]
}

@test "every Validation item is classified script-verifiable or LLM-checkable" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- / && !/^- \[(script-verifiable|LLM-checkable)\]/ { bad++ }
    END { print bad + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "circular-dependency check is classified script-verifiable" {
  # Per epic design and VCP-CHK-37 audit: "No circular dependencies" MUST
  # land on script-verifiable (topological sort is tractable in bash/awk).
  run grep -E '^\- \[script-verifiable\].*(circular dependencies|topological sort)' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "SKILL.md ## Validation sits between ## Steps and ## Finalize" {
  run awk '
    /^## Steps/      { steps = NR }
    /^## Validation/ { validation = NR }
    /^## Finalize/   { finalize = NR }
    END {
      if (steps > 0 && validation > 0 && finalize > 0 \
          && validation > steps && validation < finalize) { print "ok" }
      else { print "bad" }
    }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# -------------------------------------------------------------------------
# Non-regression (AC5): checkpoint + lifecycle event still run on
# positive path. Observability must not be contingent on checklist.
# -------------------------------------------------------------------------

@test "Non-regression: checkpoint written on positive path" {
  export EPICS_ARTIFACT="$FIXTURES/epics-and-stories-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/create-epics-stories.yaml" ] \
    || [ -f "$CHECKPOINT_PATH/gaia-create-epics.yaml" ]
}
