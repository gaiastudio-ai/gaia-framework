#!/usr/bin/env bats
# action-skill-contract.bats — per-skill action-skill contract for
# gaia-test-automate (E75-S2, FR-RSV2-46, FR-RSV2-47, ADR-075, ADR-077).
#
# Action-skill contract verifies that the skill produces a structured verdict
# (APPROVE | REQUEST_CHANGES | BLOCKED, equivalent to PASSED/FAILED/UNVERIFIED
# in Review Gate vocabulary) from its action output.
#
# Tier 1: evidence — action-results document with plan + execution outcome flags
# Tier 2: judgment — action findings (placeholders, mocks_sut, breaks_suite)
# Tier 3: verdict — verdict-resolver --action-mode canonical verdict

load '../parity_helpers.bash'

bats_require_minimum_version 1.5.0

SKILL_NAME='gaia-test-automate'

setup() {
  common_setup
  EVIDENCE="$BATS_TEST_DIRNAME/fixtures/evidence.json"
  FINDINGS="$BATS_TEST_DIRNAME/fixtures/findings.json"
  EXPECTED_VERDICT_FILE="$BATS_TEST_DIRNAME/fixtures/expected-verdict.txt"
}

teardown() {
  common_teardown
}

@test "${SKILL_NAME}: tier 1 — evidence collection produces structured analysis-results JSON" {
  assert_evidence_structured "$EVIDENCE"
  # Action-skill outcome flags are required for action-mode verdict resolution.
  run jq -e '.plan == "present" and .execution == "success"' "$EVIDENCE"
  [ "$status" -eq 0 ]
}

@test "${SKILL_NAME}: tier 2 — judgment maps evidence to findings with severities" {
  assert_judgment_findings "$FINDINGS"
  # Action-skill outcome flags live in the evidence document itself; the
  # judgment tier exposes them through the action-mode contract.
  run jq -e '.placeholders == false and .mocks_sut == false and .breaks_suite == false' "$EVIDENCE"
  [ "$status" -eq 0 ]
}

@test "${SKILL_NAME}: tier 3 — verdict resolver --action-mode emits canonical verdict" {
  run --separate-stderr run_verdict_resolver_action_mode "$SKILL_NAME" "$EVIDENCE"
  [ "$status" -eq 0 ]
  assert_verdict_canonical "$output"
  expected="$(cat "$EXPECTED_VERDICT_FILE")"
  [ "$output" = "$expected" ]
}

@test "${SKILL_NAME}: bats sources shared test_helper.bash (AC6)" {
  declare -F common_setup >/dev/null
}

@test "${SKILL_NAME}: fixtures live in co-located fixtures/ subdirectory (AC7)" {
  [ -d "$BATS_TEST_DIRNAME/fixtures" ]
  [ -f "$EVIDENCE" ]
  [ -f "$FINDINGS" ]
  [ -f "$EXPECTED_VERDICT_FILE" ]
}
