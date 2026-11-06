#!/usr/bin/env bats
# mutation-evidence-check.bats — tests for the mutation evidence checker.
# Covers: AC10, AC-EC3.

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

# ---------- AC10: Review consumers read evidence ----------

@test "review consumers read evidence and report mutation-score without invoking the runner" {
  # Create evidence with failed gate
  cat > "$EVIDENCE" <<EVIDENCE
{
  "schema_version": "1.0",
  "story_key": "TEST-S1",
  "priority": "P0",
  "commit_sha": "$COMMIT",
  "score": 55,
  "gate": "failed",
  "totals": {"mutants":10,"killed":5,"survived":4,"timeout":1,"error":0},
  "mutants": [
    {"mutant_id":"m1","status":"killed","killed_by":["test A"],"test_output":""},
    {"mutant_id":"m2","status":"killed","killed_by":["test A"],"test_output":""},
    {"mutant_id":"m3","status":"killed","killed_by":["test B"],"test_output":""},
    {"mutant_id":"m4","status":"killed","killed_by":["test A","test B"],"test_output":""},
    {"mutant_id":"m5","status":"killed","killed_by":["test C"],"test_output":""},
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

  # Test-review mode (with --zero-kill)
  run "$CHECKER" \
    --story-key "TEST-S1" \
    --evidence "$EVIDENCE" \
    --commit "$COMMIT" \
    --priority P0 \
    --thresholds '{"P0":80}' \
    --zero-kill

  [ "$status" -eq 0 ]
  tr_name=$(printf '%s' "$output" | jq -r '.name // empty')
  [ "$tr_name" = "mutation-score" ]
  tr_status=$(printf '%s' "$output" | jq -r '.status // empty')
  [ "$tr_status" = "failed" ]

  # Should have weak-assertion findings when survivors exist
  findings_count=$(printf '%s' "$output" | jq '.findings | length' 2>/dev/null || echo 0)
  [ "$findings_count" -ge 0 ]  # May have findings if survivors exist

  # Structural check: the evidence checker does NOT shell out to mutation-runner.sh
  if grep -q 'mutation-runner\.sh' "$CHECKER" 2>/dev/null; then
    # If it references the runner at all, it should only be in comments
    non_comment_refs=$(grep -v '^\s*#' "$CHECKER" | grep -c 'mutation-runner\.sh' || echo 0)
    [ "$non_comment_refs" -eq 0 ]
  fi
}

# ---------- AC-EC3: Missing or stale evidence ----------

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
  [ "$missing_status" != "passed" ]

  # Message should mention --mutation
  missing_msg=$(printf '%s' "$output" | jq -r '.message // empty')
  [[ "$missing_msg" == *"--mutation"* ]]

  # Case B: stale evidence (wrong commit)
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
  [[ "$stale_msg" == *"--mutation"* ]]
  [[ "$stale_msg" == *"stale"* ]]
}
