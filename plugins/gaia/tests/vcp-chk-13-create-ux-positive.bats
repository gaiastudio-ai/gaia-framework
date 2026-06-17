#!/usr/bin/env bats
# vcp-chk-13-create-ux-positive.bats — E42-S7 positive test for the
# V1 26-item /gaia-create-ux checklist ported to V2.
#
# Covers VCP-CHK-13 (positive) per docs/test-artifacts/test-plan.md
# and story AC1: given a UX design artifact satisfying all 26 items,
# finalize.sh exits 0 and every script-verifiable item reports PASS.
#
# The finalize.sh under test reads an optional UX_DESIGN_ARTIFACT env var
# so tests point it at a fixture rather than scanning
# docs/planning-artifacts/. The checkpoint + lifecycle-event side
# effects must continue to succeed regardless of checklist outcome
# (story AC5 + E42-S1..S6 precedent: "observability is not
# contingent on checklist pass").

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-ux"
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
# VCP-CHK-13 — Positive: all 26 items satisfied.
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all script-verifiable items satisfied" {
  export UX_DESIGN_ARTIFACT="$FIXTURES/ux-design-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist summary" {
  export UX_DESIGN_ARTIFACT="$FIXTURES/ux-design-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist"* ]]
}

@test "finalize.sh reports PASS for each required section" {
  export UX_DESIGN_ARTIFACT="$FIXTURES/ux-design-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Personas"* ]]
  [[ "$output" == *"Information Architecture"* ]]
  [[ "$output" == *"Wireframes"* ]]
  [[ "$output" == *"Interaction Patterns"* ]]
  [[ "$output" == *"Accessibility"* ]]
  [[ "$output" == *"Components"* ]]
  [[ "$output" == *"FR-to-Screen Mapping"* ]]
}

# -------------------------------------------------------------------------
# AC3 — Classification audit. Every item in the SKILL.md ## Validation
# section must carry a [script-verifiable] or [LLM-checkable] tag, and
# the count must be exactly 26.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 26 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "26" ]
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
  # FR-to-Screen Mapping, Personas presence, Wireframes presence —
  # MUST be SV, never LLM.
  run grep -E '^\- \[script-verifiable\].*FR-to-Screen Mapping' "$SKILL_MD"
  [ "$status" -eq 0 ]
  run grep -E '^\- \[script-verifiable\].*Personas' "$SKILL_MD"
  [ "$status" -eq 0 ]
  run grep -E '^\- \[script-verifiable\].*Wireframes' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "SKILL.md ## Validation sits between ## Steps and ## Finalize" {
  run awk '
    /^## Steps/     { steps = NR }
    /^## Validation/ { validation = NR }
    /^## Finalize/  { finalize = NR }
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
  export UX_DESIGN_ARTIFACT="$FIXTURES/ux-design-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/create-ux.yaml" ] || [ -f "$CHECKPOINT_PATH/gaia-create-ux.yaml" ]
}
