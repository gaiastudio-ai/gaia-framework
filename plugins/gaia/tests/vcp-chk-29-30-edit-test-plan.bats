#!/usr/bin/env bats
# vcp-chk-29-30-edit-test-plan.bats — E42-S14 positive + negative tests
# for the V1 21-item /gaia-edit-test-plan checklist ported to V2.
#
# Covers VCP-CHK-29 (positive) and VCP-CHK-30 (negative) per
# docs/test-artifacts/test-plan.md and story AC1, AC2, AC3, AC4, AC5.
#
# The finalize.sh under test reads EDITED_TEST_PLAN_ARTIFACT (fixture
# path) so tests point at per-test fixtures rather than scanning the
# repo working tree. Checkpoint + lifecycle-event side effects continue
# to succeed regardless of checklist outcome (story AC5).

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s14-edit-test-plan"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-edit-test-plan"
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
# VCP-CHK-29 — Positive: all 21 items mapped (7 SV PASS, 14 LLM deferred).
# -------------------------------------------------------------------------

@test "VCP-CHK-29: finalize.sh exits 0 when all 7 script-verifiable items satisfied" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "VCP-CHK-29: finalize.sh emits a checklist header on positive path" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist: /gaia-edit-test-plan (21 items"* ]]
}

@test "VCP-CHK-29: finalize.sh reports 7/7 script-verifiable PASS" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"7/7 script-verifiable items PASS"* ]]
}

@test "VCP-CHK-29: finalize.sh reports total items: 21" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total items: 21"* ]]
}

@test "VCP-CHK-29: every SV-01..SV-07 item appears as PASS verbatim" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] SV-01 — Output file saved to .gaia/artifacts/test-artifacts/test-plan.md"* ]]
  [[ "$output" == *"[PASS] SV-02 — Output artifact is non-empty"* ]]
  [[ "$output" == *"[PASS] SV-03 — Version History section present"* ]]
  [[ "$output" == *"[PASS] SV-04 — Version History row with date"* ]]
  [[ "$output" == *"[PASS] SV-05 — Test area section headers present"* ]]
  [[ "$output" == *"[PASS] SV-06 — Test case ID convention followed"* ]]
  [[ "$output" == *"[PASS] SV-07 — Validates field maps to FR/NFR IDs"* ]]
}

@test "VCP-CHK-29: finalize.sh enumerates 14 LLM-checkable items" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  llm_count="$(printf '%s\n' "$output" | grep -cE '^  LLM-[0-9]+ —')"
  [ "$llm_count" = "14" ]
}

@test "VCP-CHK-29: finalize.sh enumerates the V1 category headers" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[V1 category: Edit Quality]"* ]]
  [[ "$output" == *"[V1 category: New Test Cases]"* ]]
  [[ "$output" == *"[V1 category: Coverage]"* ]]
  [[ "$output" == *"[reconciled from V1 instruction step outputs]"* ]]
}

# -------------------------------------------------------------------------
# VCP-CHK-30 — Negative: artifact missing Version History (SV-03 + SV-04).
# -------------------------------------------------------------------------

@test "VCP-CHK-30: finalize.sh exits non-zero when Version History missing" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-version-history.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "VCP-CHK-30: finalize.sh names SV-03 (Version History heading) in violations" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-version-history.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SV-03 — Version History section present"* ]]
}

@test "VCP-CHK-30: finalize.sh names SV-04 (Version History row) in violations" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-version-history.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SV-04 — Version History row"* ]]
}

@test "VCP-CHK-30: finalize.sh prints Checklist violations header on failure" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-version-history.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations:"* ]]
}

@test "VCP-CHK-30: violations block lists exactly 2 SV failures" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-version-history.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  violations="$(printf '%s\n' "$output" \
    | awk '/^Checklist violations:/ { in_sec = 1; next } in_sec && /^  - / { print } in_sec && !/^  - / && !/^Checklist violations:/ { in_sec = 0 }')"
  count="$(printf '%s\n' "$violations" | grep -c '^  - ')"
  [ "$count" = "2" ]
}

@test "VCP-CHK-30: finalize.sh guides user back to /gaia-edit-test-plan" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-version-history.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/gaia-edit-test-plan"* ]]
}

# -------------------------------------------------------------------------
# AC3 — Classification audit on SKILL.md ## Validation section.
# -------------------------------------------------------------------------

@test "AC3: SKILL.md ## Validation section contains exactly 21 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "21" ]
}

@test "AC3: SKILL.md script-verifiable count is 7" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[script-verifiable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "AC3: SKILL.md LLM-checkable count is 14" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[LLM-checkable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "14" ]
}

@test "AC3: every Validation item is classified script-verifiable or LLM-checkable" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- / && !/^- \[(script-verifiable|LLM-checkable)\]/ { bad++ }
    END { print bad + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "AC3: SKILL.md ## Validation sits between ## Steps and ## Finalize" {
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
# AC5 — Non-regression: checkpoint + lifecycle event still run on both
# positive and negative paths.
# -------------------------------------------------------------------------

@test "AC5: checkpoint written on positive path" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/edit-test-plan.yaml" ]
}

@test "AC5: checkpoint written even when checklist fails" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-version-history.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/edit-test-plan.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — EDITED_TEST_PLAN_ARTIFACT pointing at missing or empty file.
# -------------------------------------------------------------------------

@test "AC4: finalize.sh reports 'no artifact to validate' when EDITED_TEST_PLAN_ARTIFACT points at a missing file" {
  export EDITED_TEST_PLAN_ARTIFACT="$BATS_TMPDIR/does-not-exist-edit-test-plan-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

@test "AC4: finalize.sh reports 'no artifact to validate' on an empty (0-byte) artifact" {
  local empty
  empty="$TEST_TMP/empty-edit-test-plan.md"
  : > "$empty"
  [ -f "$empty" ]
  [ ! -s "$empty" ]
  export EDITED_TEST_PLAN_ARTIFACT="$empty"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

# -------------------------------------------------------------------------
# Idempotency — running twice produces identical output.
# -------------------------------------------------------------------------

@test "Idempotency: positive run is repeatable" {
  export EDITED_TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  first_status="$status"
  first_output="$output"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" = "$first_status" ]
  [ "$output" = "$first_output" ]
}

# -------------------------------------------------------------------------
# WORKFLOW_NAME integrity — MUST remain "edit-test-plan" (matches V1 id).
# -------------------------------------------------------------------------

@test "WORKFLOW_NAME in finalize.sh is edit-test-plan" {
  run grep -E '^WORKFLOW_NAME="edit-test-plan"' "$FINALIZE"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC-EC8 — Shell metacharacter safety (parity with sibling E42-S* tests).
# -------------------------------------------------------------------------

@test "AC-EC8: shell metacharacters in EDITED_TEST_PLAN_ARTIFACT do not cause command injection" {
  local crafted
  crafted="$TEST_TMP/weird; name \$(touch $TEST_TMP/injected).md"
  export EDITED_TEST_PLAN_ARTIFACT="$crafted"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [ ! -f "$TEST_TMP/injected" ]
}
