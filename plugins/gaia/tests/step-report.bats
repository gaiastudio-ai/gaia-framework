#!/usr/bin/env bats
# step-report.bats — per-story step report (timing + token rollup)
#
# Covers the capstone read-only report that joins per-step timing with
# per-step token estimates into per-story tables + rollup totals.
#
# Fixture design:
#   events-3step.jsonl        — E960-S1, 4 step_boundary events (3 measured steps),
#                               all with tokens_snapshot.  Known epoch diffs:
#                               step 1=5min, step 2=8min, step 3=12min.
#                               Token diffs: hand-computed consecutive diffs.
#   events-missing-tokens.jsonl — E960-S2, step 2 lacks tokens_snapshot.
#                               Steps 1 and 2 token cells = n/a (needs BOTH
#                               consecutive snapshots). Only step 3 has tokens.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/step-report.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/step-report"
  EVENTS_3STEP="$FIXTURE_DIR/events-3step.jsonl"
  EVENTS_MISSING="$FIXTURE_DIR/events-missing-tokens.jsonl"

  TEST_TMP="$BATS_TEST_TMPDIR/sr-$$"
  mkdir -p "$TEST_TMP"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ---------- AC1 / rollup math: per-step durations sum to per-story total ----------

@test "per-step durations sum to per-story total wall-clock" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP" --json
  [ "$status" -eq 0 ]
  # step 1=5, step 2=8, step 3=12 => total=25
  total=$(echo "$output" | jq -r '.stories[0].total_duration_min')
  [ "$total" -eq 25 ]
  # Verify individual steps
  s1=$(echo "$output" | jq -r '.stories[0].steps[0].duration_min')
  s2=$(echo "$output" | jq -r '.stories[0].steps[1].duration_min')
  s3=$(echo "$output" | jq -r '.stories[0].steps[2].duration_min')
  [ "$s1" -eq 5 ]
  [ "$s2" -eq 8 ]
  [ "$s3" -eq 12 ]
  # sum check
  computed_total=$(( s1 + s2 + s3 ))
  [ "$computed_total" -eq "$total" ]
}

@test "per-step token estimates sum to per-story total token estimate" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP" --json
  [ "$status" -eq 0 ]
  # step 1: input=3200, output=1400, cache_creation=170, cache_read=400
  # step 2: input=3200, output=1200, cache_creation=170, cache_read=400
  # step 3: input=2600, output=1400, cache_creation=160, cache_read=400
  # total:  input=9000, output=4000, cache_creation=500, cache_read=1200
  total_input=$(echo "$output" | jq -r '.stories[0].total_tokens_approx.input_tokens')
  total_output=$(echo "$output" | jq -r '.stories[0].total_tokens_approx.output_tokens')
  total_cc=$(echo "$output" | jq -r '.stories[0].total_tokens_approx.cache_creation_input_tokens')
  total_cr=$(echo "$output" | jq -r '.stories[0].total_tokens_approx.cache_read_input_tokens')
  [ "$total_input" -eq 9000 ]
  [ "$total_output" -eq 4000 ]
  [ "$total_cc" -eq 500 ]
  [ "$total_cr" -eq 1200 ]
  # Verify summing individual steps matches the total
  s1_in=$(echo "$output" | jq -r '.stories[0].steps[0].tokens.input_tokens')
  s2_in=$(echo "$output" | jq -r '.stories[0].steps[1].tokens.input_tokens')
  s3_in=$(echo "$output" | jq -r '.stories[0].steps[2].tokens.input_tokens')
  computed=$(( s1_in + s2_in + s3_in ))
  [ "$computed" -eq "$total_input" ]
}

@test "text mode emits per-step rows with duration and token columns" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP"
  [ "$status" -eq 0 ]
  # Verify step rows are present
  echo "$output" | grep -Eq 'load-story.*5 min'
  echo "$output" | grep -Eq 'validate.*8 min'
  echo "$output" | grep -Eq 'implement.*12 min'
  # Verify total line
  echo "$output" | grep -Eq 'Total wall-clock.*25 min'
}

@test "text mode labels token estimates as approximate" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP"
  [ "$status" -eq 0 ]
  # Token values must always be labelled approximate
  echo "$output" | grep -Eq 'approx'
  # Total token line must say approximate
  echo "$output" | grep -Eq 'Total token estimate.*approx'
}

@test "last step (open-ended) is excluded from the table" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP" --json
  [ "$status" -eq 0 ]
  # Only 3 measured steps (step 4 is open-ended boundary, not a measured step)
  step_count=$(echo "$output" | jq '.stories[0].steps | length')
  [ "$step_count" -eq 3 ]
}

# ---------- AC2: n/a rendering for missing token cells ----------

@test "steps with missing token snapshots render n/a in text mode" {
  run bash "$SCRIPT" --events "$EVENTS_MISSING"
  [ "$status" -eq 0 ]
  # Steps 1 and 2 should have n/a tokens (step 1: next has no snapshot;
  # step 2: self has no snapshot)
  # The word n/a must appear for the steps without token data
  echo "$output" | grep -Eq 'load-story.*n/a'
  echo "$output" | grep -Eq 'validate.*n/a'
}

@test "steps with missing tokens have null tokens in JSON" {
  run bash "$SCRIPT" --events "$EVENTS_MISSING" --json
  [ "$status" -eq 0 ]
  # Steps 0 and 1 (0-indexed) should have null tokens
  s0_tok=$(echo "$output" | jq '.stories[0].steps[0].tokens')
  s1_tok=$(echo "$output" | jq '.stories[0].steps[1].tokens')
  [ "$s0_tok" = "null" ]
  [ "$s1_tok" = "null" ]
  # Step 2 should have real tokens
  s2_tok=$(echo "$output" | jq '.stories[0].steps[2].tokens')
  [ "$s2_tok" != "null" ]
}

@test "total token estimate excludes n/a steps" {
  run bash "$SCRIPT" --events "$EVENTS_MISSING" --json
  [ "$status" -eq 0 ]
  # Only step 3 contributes: input=3000, output=1500, cache_creation=200, cache_read=300
  total_input=$(echo "$output" | jq -r '.stories[0].total_tokens_approx.input_tokens')
  total_output=$(echo "$output" | jq -r '.stories[0].total_tokens_approx.output_tokens')
  [ "$total_input" -eq 3000 ]
  [ "$total_output" -eq 1500 ]
}

@test "text mode never implies exact token count" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP"
  [ "$status" -eq 0 ]
  # Every token number must be preceded by ~ or labelled approx — never bare
  # Check that no bare numeric token count appears without the approximate marker
  # All token mentions should have "approx" on the same line
  token_lines=$(echo "$output" | grep -i 'tok' || true)
  [ -n "$token_lines" ]
  while IFS= read -r line; do
    echo "$line" | grep -Eiq '(approx|n/a|estimated)' \
      || { echo "line implies exact token count: $line" >&2; false; }
  done <<< "$token_lines"
}

# ---------- AC3: --json and text modes, read-only ----------

@test "json produces valid JSON" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "text mode produces human-readable table" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP"
  [ "$status" -eq 0 ]
  # Must have a story header and a table-like structure
  echo "$output" | grep -Eq 'E960-S1'
  echo "$output" | grep -Eq 'Step'
}

@test "script is read-only (writes nothing to disk)" {
  before=$(cd "$REPO_ROOT" && git status --porcelain=v1 2>/dev/null | sort)
  fbefore=$(find "$FIXTURE_DIR" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')
  run bash "$SCRIPT" --events "$EVENTS_3STEP"
  [ "$status" -eq 0 ]
  after=$(cd "$REPO_ROOT" && git status --porcelain=v1 2>/dev/null | sort)
  fafter=$(find "$FIXTURE_DIR" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')
  [ "$fbefore" = "$fafter" ] || { echo "fixture files mutated" >&2; false; }
  [ "$before" = "$after" ] || { echo "working tree mutated:" >&2; diff <(echo "$before") <(echo "$after") >&2; false; }
}

@test "story flag filters to a single story" {
  # Create a fixture with two stories
  cat > "$TEST_TMP/multi-story.jsonl" <<'EOF'
{"timestamp":"2026-06-01T10:00:00.000Z","event_type":"step_boundary","workflow":"dev-story","pid":300,"story_key":"E960-S1","step":1,"data":{"step_name":"load-story","tokens_snapshot":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":100,"cache_read_input_tokens":200}}}
{"timestamp":"2026-06-01T10:05:00.000Z","event_type":"step_boundary","workflow":"dev-story","pid":301,"story_key":"E960-S1","step":2,"data":{"step_name":"validate","tokens_snapshot":{"input_tokens":2000,"output_tokens":1000,"cache_creation_input_tokens":200,"cache_read_input_tokens":400}}}
{"timestamp":"2026-06-01T11:00:00.000Z","event_type":"step_boundary","workflow":"dev-story","pid":302,"story_key":"E960-S3","step":1,"data":{"step_name":"load-story","tokens_snapshot":{"input_tokens":500,"output_tokens":250,"cache_creation_input_tokens":50,"cache_read_input_tokens":100}}}
{"timestamp":"2026-06-01T11:10:00.000Z","event_type":"step_boundary","workflow":"dev-story","pid":303,"story_key":"E960-S3","step":2,"data":{"step_name":"validate","tokens_snapshot":{"input_tokens":1500,"output_tokens":750,"cache_creation_input_tokens":150,"cache_read_input_tokens":300}}}
EOF
  run bash "$SCRIPT" --events "$TEST_TMP/multi-story.jsonl" --story E960-S3 --json
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq '.stories | length')
  [ "$count" -eq 1 ]
  key=$(echo "$output" | jq -r '.stories[0].story_key')
  [ "$key" = "E960-S3" ]
}

# ---------- AC4: rollup math proofs ----------

@test "sum of per-step durations equals per-story total (rollup proof)" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP" --json
  [ "$status" -eq 0 ]
  # Extract all step durations and verify their sum equals total
  step_sum=$(echo "$output" | jq '[.stories[0].steps[].duration_min] | add')
  total=$(echo "$output" | jq '.stories[0].total_duration_min')
  [ "$step_sum" -eq "$total" ]
}

@test "sum of available token estimates equals per-story total (rollup proof)" {
  run bash "$SCRIPT" --events "$EVENTS_3STEP" --json
  [ "$status" -eq 0 ]
  # Sum input_tokens across steps where tokens is not null
  step_input_sum=$(echo "$output" | jq '[.stories[0].steps[] | select(.tokens != null) | .tokens.input_tokens] | add')
  total_input=$(echo "$output" | jq '.stories[0].total_tokens_approx.input_tokens')
  [ "$step_input_sum" -eq "$total_input" ]
  # Same for output_tokens
  step_output_sum=$(echo "$output" | jq '[.stories[0].steps[] | select(.tokens != null) | .tokens.output_tokens] | add')
  total_output=$(echo "$output" | jq '.stories[0].total_tokens_approx.output_tokens')
  [ "$step_output_sum" -eq "$total_output" ]
}

@test "n/a steps excluded from token total (missing-tokens fixture)" {
  run bash "$SCRIPT" --events "$EVENTS_MISSING" --json
  [ "$status" -eq 0 ]
  # Steps 0 and 1 have null tokens; only step 2 contributes
  available_count=$(echo "$output" | jq '[.stories[0].steps[] | select(.tokens != null)] | length')
  [ "$available_count" -eq 1 ]
  # The total must match only step 2's tokens
  step_input=$(echo "$output" | jq '[.stories[0].steps[] | select(.tokens != null) | .tokens.input_tokens] | add')
  total_input=$(echo "$output" | jq '.stories[0].total_tokens_approx.input_tokens')
  [ "$step_input" -eq "$total_input" ]
}

@test "duration rollup for missing-tokens fixture" {
  run bash "$SCRIPT" --events "$EVENTS_MISSING" --json
  [ "$status" -eq 0 ]
  # step 1=10, step 2=10, step 3=15 => total=35
  total=$(echo "$output" | jq '.stories[0].total_duration_min')
  [ "$total" -eq 35 ]
  step_sum=$(echo "$output" | jq '[.stories[0].steps[].duration_min] | add')
  [ "$step_sum" -eq "$total" ]
}

# ---------- Robustness ----------

@test "empty events file produces empty report (no error)" {
  : > "$TEST_TMP/empty.jsonl"
  run bash "$SCRIPT" --events "$TEST_TMP/empty.jsonl"
  [ "$status" -eq 0 ]
}

@test "empty events file --json produces valid empty JSON" {
  : > "$TEST_TMP/empty.jsonl"
  run bash "$SCRIPT" --events "$TEST_TMP/empty.jsonl" --json
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq '.stories | length')
  [ "$count" -eq 0 ]
}

@test "missing events file fails loudly (nonzero exit)" {
  run bash "$SCRIPT" --events "$TEST_TMP/nope.jsonl"
  [ "$status" -ne 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'step-report'
}

@test "non-step_boundary events are ignored" {
  # Create a fixture mixing step_boundary with state_transition events
  cat > "$TEST_TMP/mixed.jsonl" <<'EOF'
{"timestamp":"2026-06-01T10:00:00.000Z","event_type":"state_transition","workflow":"sprint-state","pid":400,"story_key":"E960-S1","data":{"from":"ready-for-dev","to":"in-progress"}}
{"timestamp":"2026-06-01T10:00:00.000Z","event_type":"step_boundary","workflow":"dev-story","pid":401,"story_key":"E960-S1","step":1,"data":{"step_name":"load-story","tokens_snapshot":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":100,"cache_read_input_tokens":200}}}
{"timestamp":"2026-06-01T10:05:00.000Z","event_type":"step_boundary","workflow":"dev-story","pid":402,"story_key":"E960-S1","step":2,"data":{"step_name":"validate","tokens_snapshot":{"input_tokens":2000,"output_tokens":1000,"cache_creation_input_tokens":200,"cache_read_input_tokens":400}}}
{"timestamp":"2026-06-01T10:05:00.000Z","event_type":"state_transition","workflow":"sprint-state","pid":403,"story_key":"E960-S1","data":{"from":"in-progress","to":"review"}}
EOF
  run bash "$SCRIPT" --events "$TEST_TMP/mixed.jsonl" --json
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq '.stories[0].steps | length')
  [ "$count" -eq 1 ]
}
