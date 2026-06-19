#!/usr/bin/env bats
# vcp-chk-33-34-atdd.bats — E42-S15 positive + negative tests
# for the V1 5-item /gaia-atdd checklist ported to V2.
#
# Covers VCP-CHK-33 (positive) and VCP-CHK-34 (negative) per
# docs/test-artifacts/test-plan.md and story AC2, AC4, AC5, AC6.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s15-atdd"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-atdd"
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
# VCP-CHK-33 — Positive: all 5 items mapped (1 SV PASS, 4 LLM deferred).
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when the script-verifiable item satisfied" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist header on positive path" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist: /gaia-atdd (5 items"* ]]
}

@test "finalize.sh reports 1/1 script-verifiable PASS" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1/1 script-verifiable items PASS"* ]]
}

@test "finalize.sh reports total items: 5" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total items: 5"* ]]
}

@test "(Test-to-AC traceability documented) appears as PASS" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] SV-01 — Test-to-AC traceability documented"* ]]
}

@test "finalize.sh enumerates 4 LLM-checkable items" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  llm_count="$(printf '%s\n' "$output" | grep -cE '^  LLM-[0-9]+ —')"
  [ "$llm_count" = "4" ]
}

@test "finalize.sh tags PASS lines with [skill: atdd]" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[skill: atdd]"* ]]
}

# -------------------------------------------------------------------------
# VCP-CHK-34 — Negative: artifact missing the AC-to-Test traceability table.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when traceability missing" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-missing-traceability.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names (Test-to-AC traceability) in violations" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-missing-traceability.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SV-01 — Test-to-AC traceability documented"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-missing-traceability.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations:"* ]]
}

@test "finalize.sh guides user back to /gaia-atdd" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-missing-traceability.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/gaia-atdd"* ]]
}

# -------------------------------------------------------------------------
# AC5 — Classification audit on SKILL.md ## Validation section.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 5 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "SKILL.md script-verifiable count is 1" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[script-verifiable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "SKILL.md LLM-checkable count is 4" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[LLM-checkable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
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
# AC6 — Non-regression: checkpoint + lifecycle event still run.
# -------------------------------------------------------------------------

@test "checkpoint written on positive path" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/atdd.yaml" ]
}

@test "checkpoint written even when checklist fails" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-missing-traceability.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/atdd.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — ATDD_ARTIFACT pointing at missing or empty file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when ATDD_ARTIFACT missing" {
  export ATDD_ARTIFACT="$BATS_TMPDIR/does-not-exist-atdd-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

@test "finalize.sh reports 'no artifact to validate' on an empty (0-byte) artifact" {
  local empty
  empty="$TEST_TMP/empty-atdd.md"
  : > "$empty"
  export ATDD_ARTIFACT="$empty"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

# -------------------------------------------------------------------------
# Idempotency.
# -------------------------------------------------------------------------

@test "Idempotency: positive run is repeatable" {
  export ATDD_ARTIFACT="$FIXTURES/atdd-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  first_status="$status"
  first_output="$output"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" = "$first_status" ]
  [ "$output" = "$first_output" ]
}

# -------------------------------------------------------------------------
# WORKFLOW_NAME integrity — MUST remain "atdd".
# -------------------------------------------------------------------------

@test "WORKFLOW_NAME in finalize.sh is atdd" {
  run grep -E '^WORKFLOW_NAME="atdd"' "$FINALIZE"
  [ "$status" -eq 0 ]
}
