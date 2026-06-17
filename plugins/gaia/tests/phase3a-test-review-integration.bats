#!/usr/bin/env bats
# phase3a-test-review-integration.bats — end-to-end integration test for the
# four Phase 3A scanners merged by phase3a-test-review.sh (E67-S1, AC5).
# Covers TC-RSV2-TESTREVIEW-5.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  DRIVER="$SCRIPTS_DIR/review-common/phase3a-test-review.sh"
  SCHEMA="$BATS_TEST_DIRNAME/../schemas/analysis-results.schema.json"
}
teardown() { common_teardown; }

# Build a workspace with one bad test file containing a smell, a flaky pattern,
# and missing tags, plus an oversized fixture.
make_workspace() {
  mkdir -p "$TEST_TMP/tests" "$TEST_TMP/fixtures"
  cat > "$TEST_TMP/tests/bad.test.ts" <<'EOF'
it("should call API and return 200 and parse JSON and set state", { retries: 3 }, () => {
  const data = "../../fixtures/users.json";
  expect(true).toBe(true);
});
EOF
  awk 'BEGIN{ for (i=0; i<600; i++) print "{}" }' > "$TEST_TMP/fixtures/big.json"
}

@test ".1: Phase 3A driver produces schema-valid analysis-results.json" {
  make_workspace
  run "$DRIVER" --story-key E67-S1 --stack ts-dev "$TEST_TMP"
  [ "$status" -eq 0 ]
  # Top-level required fields present.
  printf '%s\n' "$output" | grep -F '"schema_version":"1.0"' >/dev/null
  printf '%s\n' "$output" | grep -F '"story_key":"E67-S1"' >/dev/null
  printf '%s\n' "$output" | grep -F '"skill":"gaia-review-test"' >/dev/null
  printf '%s\n' "$output" | grep -F '"model_temperature":0' >/dev/null
  printf '%s\n' "$output" | grep -F '"checks":[' >/dev/null
}

@test ".2: all four scanners contribute checks entries" {
  make_workspace
  run "$DRIVER" --story-key E67-S1 --stack ts-dev "$TEST_TMP"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"name":"smell-detector"' >/dev/null
  printf '%s\n' "$output" | grep -F '"name":"flakiness-analyzer"' >/dev/null
  printf '%s\n' "$output" | grep -F '"name":"fixture-analyzer"' >/dev/null
  printf '%s\n' "$output" | grep -F '"name":"tag-conformance-detector"' >/dev/null
}

@test ".3: smell + flakiness + tag findings each surface for the bad fixture" {
  make_workspace
  run "$DRIVER" --story-key E67-S1 --stack ts-dev "$TEST_TMP"
  [ "$status" -eq 0 ]
  # test-name-says-too-much (smell)
  printf '%s\n' "$output" | grep -F '"rule":"test-name-says-too-much"' >/dev/null
  # retry-heuristic (flakiness)
  printf '%s\n' "$output" | grep -F '"rule":"retry-heuristic"' >/dev/null
  # oversized-fixture (fixture)
  printf '%s\n' "$output" | grep -F '"rule":"oversized-fixture"' >/dev/null
  # missing-tag (tag-conformance)
  printf '%s\n' "$output" | grep -F '"rule":"missing-tag"' >/dev/null
}

@test ".4: schema validation passes when ajv is available" {
  make_workspace
  run "$DRIVER" --story-key E67-S1 --stack ts-dev "$TEST_TMP"
  [ "$status" -eq 0 ]
  if ! command -v ajv >/dev/null 2>&1; then
    skip "ajv not installed — schema validation skipped (AC7 covered by structural greps in 5.1)"
  fi
  local out_file="$TEST_TMP/analysis-results.json"
  printf '%s\n' "$output" > "$out_file"
  run ajv validate -s "$SCHEMA" -d "$out_file"
  [ "$status" -eq 0 ]
}

@test ".5: schema validation passes when python jsonschema is available" {
  make_workspace
  run "$DRIVER" --story-key E67-S1 --stack ts-dev "$TEST_TMP"
  [ "$status" -eq 0 ]
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi
  if ! python3 -c "import jsonschema" 2>/dev/null; then
    skip "python jsonschema not installed — schema validation skipped (AC7 covered by 5.1)"
  fi
  local out_file="$TEST_TMP/analysis-results.json"
  printf '%s\n' "$output" > "$out_file"
  run python3 -c "
import json, sys, jsonschema
schema = json.load(open('$SCHEMA'))
data = json.load(open('$out_file'))
jsonschema.validate(data, schema)
"
  [ "$status" -eq 0 ]
}

@test ".6: clean workspace produces all-passed checks" {
  mkdir -p "$TEST_TMP/tests"
  cat > "$TEST_TMP/tests/clean.test.ts" <<'EOF'
import { fixtures } from "./fixtures";
describe.each([[1],[2]])("clean %i", (x) => {
  it("works", () => { expect(x).toBe(x); });
});
EOF
  run "$DRIVER" --story-key E67-S1 --stack ts-dev "$TEST_TMP"
  [ "$status" -eq 0 ]
  # No "failed" status across the four checks — every check is "passed".
  ! printf '%s\n' "$output" | grep -F '"status":"failed"' >/dev/null
}

@test ".7: --story-key validation rejects non-canonical keys" {
  run "$DRIVER" --story-key bogus --stack ts-dev "$TEST_TMP"
  [ "$status" -eq 1 ]
}

@test ".8: --stack required" {
  run "$DRIVER" --story-key E67-S1 "$TEST_TMP"
  [ "$status" -eq 1 ]
}

@test ".9: phase3a driver does not invoke jq as a runtime command" {
  ! grep -vE '^[[:space:]]*#' "$DRIVER" | grep -E '(^|[[:space:]\|;])jq([[:space:]]|$)' >/dev/null
}

@test ".10: phase3a driver uses set -euo pipefail and LC_ALL=C" {
  grep -Fq "set -euo pipefail" "$DRIVER"
  grep -Fq "LC_ALL=C" "$DRIVER"
}
