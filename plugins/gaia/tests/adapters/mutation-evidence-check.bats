#!/usr/bin/env bats
# mutation-evidence-check.bats — tests for the mutation evidence checker.

load '../test_helper.bash'

setup() {
  BATS_TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIR/../.." && pwd)"
  CHECKER="$PLUGIN_ROOT/scripts/review-common/mutation-evidence-check.sh"

  [ -x "$CHECKER" ] || { echo "mutation-evidence-check.sh not found at $CHECKER" >&2; return 1; }

  TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mec-bats-XXXXXX")
  EVIDENCE="$TEST_TMP/evidence.json"
  COMMIT="abc123def456"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------- Review consumers read evidence and report mutation-score ----------

@test "review consumers read evidence and report mutation-score without invoking the runner" {
  cat > "$EVIDENCE" <<EVIDENCE
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "priority": "P0",
  "commit_sha": "$COMMIT",
  "score": 55,
  "gate": "failed",
  "totals": {"mutants":10,"killed":5,"survived":4,"timeout":1,"error":0},
  "covering_tests": ["tests/alpha.bats", "tests/beta.bats", "tests/gamma.bats"],
  "mutants": [
    {"mutant_id":"m1","status":"killed","killed_by":["tests/alpha.bats"],"test_output":""},
    {"mutant_id":"m2","status":"killed","killed_by":["tests/alpha.bats"],"test_output":""},
    {"mutant_id":"m3","status":"killed","killed_by":["tests/beta.bats"],"test_output":""},
    {"mutant_id":"m4","status":"killed","killed_by":["tests/alpha.bats","tests/beta.bats"],"test_output":""},
    {"mutant_id":"m5","status":"killed","killed_by":["tests/gamma.bats"],"test_output":""},
    {"mutant_id":"m6","status":"survived","killed_by":[],"test_output":""},
    {"mutant_id":"m7","status":"survived","killed_by":[],"test_output":""},
    {"mutant_id":"m8","status":"survived","killed_by":[],"test_output":""},
    {"mutant_id":"m9","status":"survived","killed_by":[],"test_output":""},
    {"mutant_id":"m10","status":"timeout","killed_by":[],"test_output":""}
  ]
}
EVIDENCE

  # QA mode (no --zero-kill)
  run "$CHECKER" \
    --story-key "TEST-S1" \
    --evidence "$EVIDENCE" \
    --commit "$COMMIT" \
    --priority P0 \
    --thresholds '{"P0":80}'

  [ "$status" -eq 0 ]
  result_name=$(printf '%s' "$output" | jq -r '.name // empty')
  [ "$result_name" = "mutation-score" ]
  result_status=$(printf '%s' "$output" | jq -r '.status // empty')
  [ "$result_status" = "failed" ]

  # Evidence checker must NOT call mutation-runner.sh
  non_comment_refs=$(grep -v '^\s*#' "$CHECKER" | grep -c 'mutation-runner\.sh' || true)
  [ "${non_comment_refs:-0}" -eq 0 ]
}

# ---------- Zero-kill findings: one per covering test ----------

@test "zero-kill mode emits one finding per covering test that killed zero mutants" {
  # Evidence where gamma.bats killed mutants but delta.bats killed nothing
  cat > "$EVIDENCE" <<EVIDENCE
{
  "schema_version": "1.0",
  "story_key": "TEST-S2",
  "priority": "P0",
  "commit_sha": "$COMMIT",
  "score": 50,
  "gate": "failed",
  "totals": {"mutants":4,"killed":2,"survived":2,"timeout":0,"error":0},
  "covering_tests": ["tests/both.bats"],
  "covering_test_names": ["gamma catches it", "delta asserts nothing"],
  "mutants": [
    {"mutant_id":"m1","status":"killed","killed_by":["gamma catches it"],"test_output":""},
    {"mutant_id":"m2","status":"killed","killed_by":["gamma catches it"],"test_output":""},
    {"mutant_id":"m3","status":"survived","killed_by":[],"test_output":""},
    {"mutant_id":"m4","status":"survived","killed_by":[],"test_output":""}
  ]
}
EVIDENCE

  run "$CHECKER" \
    --story-key "TEST-S2" \
    --evidence "$EVIDENCE" \
    --commit "$COMMIT" \
    --priority P0 \
    --thresholds '{"P0":80}' \
    --zero-kill

  [ "$status" -eq 0 ]

  # One weak-assertion finding: the delta test killed nothing, gamma killed two.
  findings_count=$(printf '%s' "$output" | jq '[.findings[] | select(.rule == "weak-assertion")] | length')
  [ "$findings_count" -eq 1 ]
  finding_msg=$(printf '%s' "$output" | jq -r '.findings[] | select(.rule == "weak-assertion") | .message')
  [[ "$finding_msg" == *"delta asserts nothing"* ]]
  [[ "$finding_msg" == *"zero mutants"* ]]

  # The failed score is itself a blocking finding.
  [ "$(printf '%s' "$output" | jq '[.findings[] | select(.blocking == true)] | length')" -eq 1 ]
}

# ---------- Missing or stale evidence ----------

@test "missing or stale mutation evidence on a P0 story reports errored and never PASSED" {
  # Case A: missing evidence
  run "$CHECKER" \
    --story-key "TEST-S1" \
    --evidence "$TEST_TMP/nonexistent.json" \
    --commit "$COMMIT" \
    --priority P0 \
    --thresholds '{"P0":80}'

  [ "$status" -eq 0 ]
  missing_status=$(printf '%s' "$output" | jq -r '.status // empty')
  [ "$missing_status" = "errored" ]

  missing_msg=$(printf '%s' "$output" | jq -r '.message // empty')
  [[ "$missing_msg" == *"--mutation"* ]]

  # Case B: stale evidence
  cat > "$EVIDENCE" <<EVIDENCE
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "priority": "P0",
  "commit_sha": "old-commit-sha",
  "score": 90,
  "gate": "passed",
  "totals": {"mutants":10,"killed":9,"survived":1,"timeout":0,"error":0},
  "mutants": []
}
EVIDENCE

  run "$CHECKER" \
    --story-key "TEST-S1" \
    --evidence "$EVIDENCE" \
    --commit "different-commit-sha" \
    --priority P0 \
    --thresholds '{"P0":80}'

  [ "$status" -eq 0 ]
  stale_status=$(printf '%s' "$output" | jq -r '.status // empty')
  [ "$stale_status" = "errored" ]
  [ "$stale_status" != "passed" ]

  stale_msg=$(printf '%s' "$output" | jq -r '.message // empty')
  [[ "$stale_msg" == *"stale"* ]]
}
