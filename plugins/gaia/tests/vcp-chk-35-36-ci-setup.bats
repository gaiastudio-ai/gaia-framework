#!/usr/bin/env bats
# vcp-chk-35-36-ci-setup.bats — E42-S15 positive + negative tests
# for the V1 8-item /gaia-ci-setup checklist ported to V2.
#
# Covers VCP-CHK-35 (positive) and VCP-CHK-36 (negative) per
# docs/test-artifacts/test-plan.md and story AC3, AC4, AC5, AC6.

load 'test_helper.bash'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/e42-s15-ci-setup"
SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-ci-setup"
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
# VCP-CHK-35 — Positive: all 8 items mapped (6 SV PASS, 2 LLM deferred).
# -------------------------------------------------------------------------

@test "finalize.sh exits 0 when all 6 script-verifiable items satisfied" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "finalize.sh emits a checklist header on positive path" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checklist: /gaia-ci-setup (8 items"* ]]
}

@test "finalize.sh reports 6/6 script-verifiable PASS" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"6/6 script-verifiable items PASS"* ]]
}

@test "finalize.sh reports total items: 8" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total items: 8"* ]]
}

@test "every .. item appears as PASS verbatim" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] SV-01 — Pipeline stages defined"* ]]
  [[ "$output" == *"[PASS] SV-02 — Quality gate thresholds set"* ]]
  [[ "$output" == *"[PASS] SV-03 — Secrets management documented"* ]]
  [[ "$output" == *"[PASS] SV-04 — Deployment strategy defined"* ]]
  [[ "$output" == *"[PASS] SV-05 — Monitoring and notifications configured"* ]]
  [[ "$output" == *"[PASS] SV-06 — Pipeline config generated"* ]]
}

@test "finalize.sh enumerates 2 LLM-checkable items" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  llm_count="$(printf '%s\n' "$output" | grep -cE '^  LLM-[0-9]+ —')"
  [ "$llm_count" = "2" ]
}

@test "finalize.sh tags PASS lines with [skill: ci-setup]" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[skill: ci-setup]"* ]]
}

# -------------------------------------------------------------------------
# VCP-CHK-36 — Negative: artifact missing the Secrets Management section.
# -------------------------------------------------------------------------

@test "finalize.sh exits non-zero when Secrets Management missing" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-missing-secrets.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "finalize.sh names (Secrets Management) in violations" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-missing-secrets.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SV-03 — Secrets management documented"* ]]
}

@test "finalize.sh prints Checklist violations header on failure" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-missing-secrets.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist violations:"* ]]
}

@test "finalize.sh guides user back to /gaia-ci-setup" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-missing-secrets.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/gaia-ci-setup"* ]]
}

# -------------------------------------------------------------------------
# AC5 — Classification audit on SKILL.md ## Validation section.
# -------------------------------------------------------------------------

@test "SKILL.md ## Validation section contains exactly 8 classified items" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[(script-verifiable|LLM-checkable)\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "8" ]
}

@test "SKILL.md script-verifiable count is 6" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[script-verifiable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "6" ]
}

@test "SKILL.md LLM-checkable count is 2" {
  run awk '
    /^## Validation/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^- \[LLM-checkable\]/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
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
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-complete.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/ci-setup.yaml" ]
}

@test "checkpoint written even when checklist fails" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-missing-secrets.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [ -f "$CHECKPOINT_PATH/ci-setup.yaml" ]
}

# -------------------------------------------------------------------------
# AC4 — CI_SETUP_ARTIFACT pointing at missing or empty file.
# -------------------------------------------------------------------------

@test "finalize.sh reports 'no artifact to validate' when CI_SETUP_ARTIFACT missing" {
  export CI_SETUP_ARTIFACT="$BATS_TMPDIR/does-not-exist-ci-setup-$$.md"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

@test "finalize.sh reports 'no artifact to validate' on an empty (0-byte) artifact" {
  local empty
  empty="$TEST_TMP/empty-ci-setup.md"
  : > "$empty"
  export CI_SETUP_ARTIFACT="$empty"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no artifact to validate"* ]]
}

# -------------------------------------------------------------------------
# Idempotency.
# -------------------------------------------------------------------------

@test "Idempotency: positive run is repeatable" {
  export CI_SETUP_ARTIFACT="$FIXTURES/ci-setup-complete.md"
  run bash -c "'$FINALIZE' 2>&1"
  first_status="$status"
  first_output="$output"
  run bash -c "'$FINALIZE' 2>&1"
  [ "$status" = "$first_status" ]
  [ "$output" = "$first_output" ]
}

# -------------------------------------------------------------------------
# WORKFLOW_NAME integrity — MUST remain "ci-setup".
# -------------------------------------------------------------------------

@test "WORKFLOW_NAME in finalize.sh is ci-setup" {
  run grep -E '^WORKFLOW_NAME="ci-setup"' "$FINALIZE"
  [ "$status" -eq 0 ]
}
