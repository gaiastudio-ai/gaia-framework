#!/usr/bin/env bats
# evidence-judgment-parity.bats — per-skill parity bats for gaia-code-review
# (E75-S2, FR-RSV2-46, ADR-075).
#
# Exercises the three-tier evidence -> judgment -> verdict pipeline for the
# gaia-code-review skill using co-located fixtures under fixtures/. Extends
# the base tests/evidence-judgment-parity.bats (E66-S5) with skill-specific
# coverage; the base file remains unchanged.
#
# Tier 1: evidence (analysis-results.json) — eslint + tsc check output
# Tier 2: judgment (llm-findings.json) — code-quality findings with severities
# Tier 3: verdict (verdict-resolver.sh) — APPROVE | REQUEST_CHANGES | BLOCKED

# parity_helpers.bash internally sources the shared tests/test_helper.bash
# (E66-S5 infrastructure) per AC6 — see parity_helpers.bash for the BATS
# path-shim that makes the cross-directory source work.
load '../parity_helpers.bash'

bats_require_minimum_version 1.5.0

SKILL_NAME='gaia-code-review'

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
  # Skill-specific: code-review evidence references the linter checks.
  run jq -r '.checks[].name' "$EVIDENCE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'eslint'
}

@test "${SKILL_NAME}: tier 2 — judgment maps evidence to findings with severities" {
  assert_judgment_findings "$FINDINGS"
}

@test "${SKILL_NAME}: tier 3 — verdict resolver emits exactly one canonical verdict" {
  # Capture stdout only — verdict-resolver writes a provenance line to stderr
  # when --skill is provided.
  run --separate-stderr run_verdict_resolver "$SKILL_NAME" "$EVIDENCE" "$FINDINGS"
  [ "$status" -eq 0 ]
  assert_verdict_canonical "$output"
  expected="$(cat "$EXPECTED_VERDICT_FILE")"
  [ "$output" = "$expected" ]
}

@test "${SKILL_NAME}: bats sources shared test_helper.bash (AC6)" {
  # Sourced via `load` at the top — verify the helper-defined function exists.
  declare -F common_setup >/dev/null
}

@test "${SKILL_NAME}: fixtures live in co-located fixtures/ subdirectory (AC7)" {
  [ -d "$BATS_TEST_DIRNAME/fixtures" ]
  [ -f "$EVIDENCE" ]
  [ -f "$FINDINGS" ]
  [ -f "$EXPECTED_VERDICT_FILE" ]
}
