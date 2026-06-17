#!/usr/bin/env bats
# vcp-chk-31-32-test-framework.bats — E42-S15 positive + negative tests
# for the V1 7-item /gaia-test-framework checklist ported to V2.
#
# Covers VCP-CHK-31 (positive) and VCP-CHK-32 (negative) per
# docs/test-artifacts/test-plan.md and story AC1, AC4, AC5, AC6.
#
# The finalize.sh under test reads TEST_FRAMEWORK_SETUP_ARTIFACT (fixture
# path) so tests point at per-test fixtures rather than scanning the
# repo working tree. Checkpoint + lifecycle-event side effects continue
# to succeed regardless of checklist outcome (story AC6).

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s15-test-framework"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-test-framework"
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
# VCP-CHK-31 — Positive: all 7 items mapped (4 SV PASS, 3 LLM deferred).
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all 4 script-verifiable items satisfied" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist header on positive path" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist: /gaia-test-framework (7 items"* ]]
}

@test "finalize.sh reports 4/4 script-verifiable PASS" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"4/4 script-verifiable items PASS"* ]]
}

@test "finalize.sh reports total items: 7" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total items: 7"* ]]
}

@test "every .. item appears as PASS verbatim" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] SV-01 — Config files generated"* ]]
  [[ "$output" == *"[PASS] SV-02 — Folder structure scaffolded"* ]]
  [[ "$output" == *"[PASS] SV-03 — Test runner script configured and executable"* ]]
  [[ "$output" == *"[PASS] SV-04 — Fixture architecture designed"* ]]
}

@test "finalize.sh enumerates 3 LLM-checkable items" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  llm_count="$(printf '%s\n' "$output" | grep -cE '^  LLM-[0-9]+ —')"
  [ "$llm_count" = "3" ]
}

@test "finalize.sh tags PASS lines with [skill: test-framework]" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[skill: test-framework]"* ]]
}

# -------------------------------------------------------------------------
# VCP-CHK-32 — Negative: artifact missing the test-runner section (SV-03).
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when test runner missing" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-missing-runner.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names (Test runner script) in violations" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-missing-runner.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SV-03 — Test runner script configured and executable"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-missing-runner.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations:"* ]]
}

@test "finalize.sh guides user back to /gaia-test-framework" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-missing-runner.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/gaia-test-framework"* ]]
}

# -------------------------------------------------------------------------
# AC5 — Classification audit on SKILL.md ## Validation section.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 7 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "SKILL.md script-verifiable count is 4" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[script-verifiable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "SKILL.md LLM-checkable count is 3" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[LLM-checkable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
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
# AC6 — Non-regression: checkpoint + lifecycle event still run on both
# positive and negative paths.
# -------------------------------------------------------------------------

@test "checkpoint written on positive path" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/test-framework.yaml" ]
}

@test "checkpoint written even when checklist fails" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-missing-runner.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/test-framework.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — TEST_FRAMEWORK_SETUP_ARTIFACT pointing at missing or empty file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when artifact path missing" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$BATS_TMPDIR/does-not-exist-test-framework-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

@test "finalize.sh reports 'no artifact to validate' on an empty (0-byte) artifact" {
  local empty
  empty="$TEST_TMP/empty-test-framework.md"
  : > "$empty"
  [ -f "$empty" ]
  [ ! -s "$empty" ]
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$empty"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

# -------------------------------------------------------------------------
# Idempotency — running twice produces identical output.
# -------------------------------------------------------------------------

@test "Idempotency: positive run is repeatable" {
  export TEST_FRAMEWORK_SETUP_ARTIFACT="$FIXTURES/test-framework-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  first_status="$status"
  first_output="$output"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" = "$first_status" ]
  [ "$output" = "$first_output" ]
}

# -------------------------------------------------------------------------
# WORKFLOW_NAME integrity — MUST remain "test-framework" (matches V1 id).
# -------------------------------------------------------------------------

@test "WORKFLOW_NAME in finalize.sh is test-framework" {
  run grep -E '^WORKFLOW_NAME="test-framework"' "$FINALIZE"
  [ "$status" -eq 0 ]
}
