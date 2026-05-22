#!/usr/bin/env bats
# vcp-chk-27-28-test-design.bats — E42-S14 positive + negative tests for
# the V1 8-item /gaia-test-design checklist ported to V2.
#
# Covers VCP-CHK-27 (positive) and VCP-CHK-28 (negative) per
# docs/test-artifacts/test-plan.md and story AC1, AC2, AC3, AC4, AC5.
#
# The finalize.sh under test reads TEST_PLAN_ARTIFACT (fixture path) so
# tests point at per-test fixtures rather than scanning the repo working
# tree. Checkpoint + lifecycle-event side effects continue to succeed
# regardless of checklist outcome (story AC5).

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s14-test-design"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-test-design"
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
# VCP-CHK-27 — Positive: all 8 items satisfied (6 SV PASS, 2 LLM deferred).
# -------------------------------------------------------------------------

@test "VCP-CHK-27: finalize.sh exits 0 when all 6 script-verifiable items satisfied" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "VCP-CHK-27: finalize.sh emits a checklist header on positive path" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist: /gaia-test-design (8 items"* ]]
}

@test "VCP-CHK-27: finalize.sh reports 6/6 script-verifiable PASS" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"6/6 script-verifiable items PASS"* ]]
}

@test "VCP-CHK-27: finalize.sh reports total items: 8" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total items: 8"* ]]
}

@test "VCP-CHK-27: every SV-01..SV-06 item appears as PASS verbatim" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] SV-01 — Output file saved to .gaia/artifacts/test-artifacts/test-plan.md"* ]]
  [[ "$output" == *"[PASS] SV-02 — Output artifact is non-empty"* ]]
  [[ "$output" == *"[PASS] SV-03 — Risk assessment section present"* ]]
  [[ "$output" == *"[PASS] SV-04 — Test strategy section present"* ]]
  [[ "$output" == *"[PASS] SV-05 — Coverage targets defined"* ]]
  [[ "$output" == *"[PASS] SV-06 — Quality gates specified for CI"* ]]
}

@test "VCP-CHK-27: finalize.sh enumerates the 2 LLM-checkable items" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM-01 — Legacy integration boundaries"* ]]
  [[ "$output" == *"LLM-02 — Data migration validation tests"* ]]
}

# -------------------------------------------------------------------------
# VCP-CHK-28 — Negative: artifact missing 1 item (SV-06 quality gates).
# -------------------------------------------------------------------------

@test "VCP-CHK-28: finalize.sh exits non-zero when SV-06 missing" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-quality-gates.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "VCP-CHK-28: finalize.sh names SV-06 in the violations block" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-quality-gates.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SV-06 — Quality gates specified for CI"* ]]
}

@test "VCP-CHK-28: finalize.sh prints Checklist violations header on failure" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-quality-gates.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations:"* ]]
}

@test "VCP-CHK-28: failure output contains exactly 1 violation row" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-quality-gates.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  violations="$(printf '%s\n' "$output" \
    | awk '/^Checklist violations:/ { in_sec = 1; next } in_sec && /^  - / { print } in_sec && !/^  - / && !/^Checklist violations:/ { in_sec = 0 }')"
  count="$(printf '%s\n' "$violations" | grep -c '^  - ')"
  [ "$count" = "1" ]
}

@test "VCP-CHK-28: finalize.sh guides user back to /gaia-test-design" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-quality-gates.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/gaia-test-design"* ]]
}

# -------------------------------------------------------------------------
# AC3 — Classification audit on SKILL.md ## Validation section.
# -------------------------------------------------------------------------

@test "AC3: SKILL.md ## Validation section contains exactly 8 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "8" ]
}

@test "AC3: SKILL.md script-verifiable count is 6" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[script-verifiable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "6" ]
}

@test "AC3: SKILL.md LLM-checkable count is 2" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[LLM-checkable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
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
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/test-design.yaml" ]
}

@test "AC5: checkpoint written even when checklist fails" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-missing-quality-gates.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/test-design.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — TEST_PLAN_ARTIFACT pointing at missing or empty file.
# -------------------------------------------------------------------------

@test "AC4: finalize.sh reports 'no artifact to validate' when TEST_PLAN_ARTIFACT points at a missing file" {
  export TEST_PLAN_ARTIFACT="$BATS_TMPDIR/does-not-exist-test-plan-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

@test "AC4: finalize.sh reports 'no artifact to validate' on an empty (0-byte) artifact" {
  local empty
  empty="$TEST_TMP/empty-test-plan.md"
  : > "$empty"
  [ -f "$empty" ]
  [ ! -s "$empty" ]
  export TEST_PLAN_ARTIFACT="$empty"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

# -------------------------------------------------------------------------
# Idempotency — running twice on the same fixture must produce identical
# stdout/stderr (modulo paths) and identical exit codes.
# -------------------------------------------------------------------------

@test "Idempotency: positive run is repeatable" {
  export TEST_PLAN_ARTIFACT="$FIXTURES/test-plan-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  first_status="$status"
  first_output="$output"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" = "$first_status" ]
  [ "$output" = "$first_output" ]
}

# -------------------------------------------------------------------------
# WORKFLOW_NAME integrity — MUST remain "test-design" (matches V1 id).
# -------------------------------------------------------------------------

@test "WORKFLOW_NAME in finalize.sh is test-design" {
  run grep -E '^WORKFLOW_NAME="test-design"' "$FINALIZE"
  [ "$status" -eq 0 ]
}
