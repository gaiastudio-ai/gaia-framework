#!/usr/bin/env bats
# evidence-judgment-parity.bats — per-skill parity bats for gaia-review-api
# (E75-S2, FR-RSV2-46, ADR-075).
#
# Tier 1: evidence — openapi-lint + swagger-validator endpoint analysis
# Tier 2: judgment — API design findings with severities + endpoint references
# Tier 3: verdict — verdict-resolver canonical verdict

load '../parity_helpers.bash'

bats_require_minimum_version 1.5.0

SKILL_NAME='gaia-review-api'

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
  run jq -r '.checks[].name' "$EVIDENCE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE 'openapi|swagger'
}

@test "${SKILL_NAME}: tier 2 — judgment maps evidence to findings with severities" {
  assert_judgment_findings "$FINDINGS"
  run jq -e '.findings | any(.endpoint != null)' "$FINDINGS"
  [ "$status" -eq 0 ]
}

@test "${SKILL_NAME}: tier 3 — verdict resolver emits exactly one canonical verdict" {
  run --separate-stderr run_verdict_resolver "$SKILL_NAME" "$EVIDENCE" "$FINDINGS"
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
