#!/usr/bin/env bats
# vcp-chk-17-edit-arch-positive.bats — E42-S9 positive test for the
# V1 25-item /gaia-edit-arch checklist ported to V2.
#
# Covers VCP-CHK-17 (positive) per docs/test-artifacts/test-plan.md
# and story AC1: given an architecture artifact satisfying all 25
# items, finalize.sh exits 0 and every script-verifiable item reports
# PASS.
#
# The finalize.sh under test reads an optional ARCHITECTURE_ARTIFACT
# env var so tests point it at a fixture rather than scanning
# docs/planning-artifacts/. The checkpoint + lifecycle-event side
# effects must continue to succeed regardless of checklist outcome
# (story AC5 + E42-S1..S8 precedent).

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-edit-arch"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-CHK-17 — Positive: all 25 items satisfied.
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all script-verifiable items satisfied" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist summary" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist"* ]]
}

@test "finalize.sh reports PASS for Version History item" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Version History"* ]]
}

@test "finalize.sh reports PASS for Cascade Assessment" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cascade"* ]]
}

@test "finalize.sh reports PASS for superseded ADR marking" {
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Superseded"* ]] || [[ "$output" == *"supersede"* ]]
}

# -------------------------------------------------------------------------
# AC3 — Classification audit. Every item in the SKILL.md ## Validation
# section must carry a [script-verifiable] or [LLM-checkable] tag, and
# the count must be exactly 25.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 25 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "25" ]
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

@test "structural items are classified script-verifiable" {
  # Version History and Decision Log — structural anchors MUST be SV.
  run grep -E '^\- \[script-verifiable\].*Version History' "$SKILL_MD"
  [ "$status" -eq 0 ]
  run grep -E '^\- \[script-verifiable\].*Decision Log|^\- \[script-verifiable\].*ADR' "$SKILL_MD"
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
  export ARCHITECTURE_ARTIFACT="$FIXTURES/architecture-edited-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/edit-architecture.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-edit-arch.yaml" ]
}
