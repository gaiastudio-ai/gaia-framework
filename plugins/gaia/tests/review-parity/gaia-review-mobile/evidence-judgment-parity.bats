#!/usr/bin/env bats
# evidence-judgment-parity.bats — per-skill parity bats for gaia-review-mobile
# (E75-S2, FR-RSV2-46, FR-RSV2-47, ADR-075, ADR-081).
#
# Mobile is a review skill but ships its own per-skill bats due to unique
# evidence sources (entitlements, signing, store metadata, privacy manifest,
# universal links — see AC3).
#
# Tier 1: evidence — entitlements + signing + store metadata + privacy manifest
#         + universal links scan output
# Tier 2: judgment — mobile findings with severities + platform + evidence_source
# Tier 3: verdict — verdict-resolver canonical verdict

load '../parity_helpers.bash'

bats_require_minimum_version 1.5.0

SKILL_NAME='gaia-review-mobile'

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
}

@test "${SKILL_NAME}: tier 1 (mobile-specific) — evidence references all five mobile sources (AC3)" {
  # AC3: mobile bats exercises mobile-specific evidence sources —
  # entitlements, signing, store metadata, privacy manifest, universal links.
  run jq -r '.checks[].subject' "$EVIDENCE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'entitlements'
  printf '%s\n' "$output" | grep -q 'signing'
  printf '%s\n' "$output" | grep -q 'store metadata'
  printf '%s\n' "$output" | grep -q 'privacy manifest'
  printf '%s\n' "$output" | grep -q 'universal links'
}

@test "${SKILL_NAME}: tier 2 — judgment maps evidence to findings with severities" {
  assert_judgment_findings "$FINDINGS"
  run jq -e '.findings | any(.platform != null and .evidence_source != null)' "$FINDINGS"
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
