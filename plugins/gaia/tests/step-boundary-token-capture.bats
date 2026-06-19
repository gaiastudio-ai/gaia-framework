#!/usr/bin/env bats
# step-boundary-token-capture.bats — best-effort per-step token capture tests
#
# Covers:
#   A. Snapshot-diff derivation (approx label + exact value)
#   B. Graceful-skip (exit 0, timing lands, n/a, no error)
#   C. Negative-diff clamped to n/a (compaction)
#   D. Privacy payload assertion (all leaves numeric, no prompt text)
#   E. Backwards-compat (no --tokens = no tokens_snapshot)
#   F. Privacy guard non-vacuity (string-bearing payload rejected)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/throughput-telemetry.sh"
  EMIT_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/scripts/emit-step-boundary.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/step-boundary-token-capture"

  TEST_TMP="$BATS_TEST_TMPDIR/tc-$$"
  mkdir -p "$TEST_TMP"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ---------- Scenario A: snapshot-diff derivation ----------

@test "with-tokens fixture yields per-step token estimates labelled approximate" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/with-tokens.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Step 1 -> Step 2: input_tokens diff = 8200-5000 = 3200
  # The output must contain the full formatted string with the approx label
  printf '%s\n' "$output" | grep -qF "~3200 tok (approx)" \
    || { echo "Missing '~3200 tok (approx)' input diff label in token output" >&2; echo "$output" >&2; false; }
}

@test "per-step token diff values are correct positive differences" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/with-tokens.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Step 1->2 diffs (fixtures chosen so every diff != any raw snapshot value):
  #   input:  8200 - 5000 = 3200  (raws: 5000, 8200, 12500 — no match)
  #   output: 2400 - 1000 = 1400  (raws: 1000, 2400, 3900 — no match)
  # Assert the full formatted diff string, not a bare number.
  printf '%s\n' "$output" | grep "step 1" | grep -qF "input: ~3200 tok (approx)" \
    || { echo "Expected 'input: ~3200 tok (approx)' for step 1" >&2; echo "$output" >&2; false; }
  printf '%s\n' "$output" | grep "step 1" | grep -qF "output: ~1400 tok (approx)" \
    || { echo "Expected 'output: ~1400 tok (approx)' for step 1" >&2; echo "$output" >&2; false; }
  # Step 2->3 diffs: input 4300, output 1500 — also distinct from all raws
  printf '%s\n' "$output" | grep "step 2" | grep -qF "input: ~4300 tok (approx)" \
    || { echo "Expected 'input: ~4300 tok (approx)' for step 2" >&2; echo "$output" >&2; false; }
  printf '%s\n' "$output" | grep "step 2" | grep -qF "output: ~1500 tok (approx)" \
    || { echo "Expected 'output: ~1500 tok (approx)' for step 2" >&2; echo "$output" >&2; false; }
}

@test "three consecutive steps yield 8 approx token fields (4 fields x 2 steps)" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/with-tokens.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Steps 1,2,3 -> diffs for steps 1 and 2 (last step is open-ended).
  # Each step line carries 4 token fields with "tok (approx)"; 2 steps = 8 total.
  local tok_count
  tok_count=$(printf '%s\n' "$output" | grep -o "tok (approx)" | wc -l | tr -d ' ')
  [ "$tok_count" -eq 8 ] \
    || { echo "Expected exactly 8 'tok (approx)' occurrences, got $tok_count" >&2; echo "$output" >&2; false; }
}

# ---------- Scenario B: graceful-skip ----------

@test "no-tokens fixture still produces timing data with exit 0" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/no-tokens.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Timing data (step durations) must still appear
  printf '%s\n' "$output" | grep -q "step 1" \
    || { echo "Expected step 1 timing in output" >&2; echo "$output" >&2; false; }
}

@test "no-tokens fixture renders explicit n/a token column" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/no-tokens.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # When tokens are absent, the output MUST contain an explicit "tokens: n/a"
  # field on every step line — stable column contract for E112-S3.
  printf '%s\n' "$output" | grep "E961-S1" | grep -qF "tokens: n/a" \
    || { echo "Expected explicit 'tokens: n/a' for no-tokens step, got:" >&2; echo "$output" >&2; false; }
  # No approximate token numbers should appear for this story
  ! printf '%s\n' "$output" | grep "E961-S1" | grep -qE '~[0-9]+ tok' \
    || { echo "Unexpected approximate token counts in no-tokens fixture" >&2; echo "$output" >&2; false; }
}

# ---------- Scenario C: negative-diff clamped to n/a ----------

@test "negative token diff (compaction) is clamped to n/a, never negative" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/negative-diff.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # input_tokens goes 15000 -> 9000 (diff = -6000). Must NOT appear as -6000.
  ! printf '%s\n' "$output" | grep -qE '\-[0-9]+ tok' \
    || { echo "Negative token count found in output" >&2; echo "$output" >&2; false; }
  # The negative field (input) should render as n/a scoped to the step line.
  # output_tokens goes 3000 -> 3500 (diff = +500), so the line has BOTH n/a and approx.
  printf '%s\n' "$output" | grep "E962-S1" | grep "step 1" | grep -qF "input: n/a" \
    || { echo "Expected 'input: n/a' for negative diff on step 1" >&2; echo "$output" >&2; false; }
  # The positive field (output) should still show an approximate value.
  printf '%s\n' "$output" | grep "E962-S1" | grep "step 1" | grep -qF "output: ~500 tok (approx)" \
    || { echo "Expected 'output: ~500 tok (approx)' for positive diff on step 1" >&2; echo "$output" >&2; false; }
}

# ---------- Scenario D: PRIVACY payload assertion ----------

@test "emit-step-boundary with --tokens produces tokens_snapshot with only numeric values" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  run bash "$EMIT_HELPER" 1 load-story E998-S1 \
    --tokens '{"input_tokens":5000,"output_tokens":1200,"cache_creation_input_tokens":0,"cache_read_input_tokens":800}'
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/lifecycle-events.jsonl" ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  # tokens_snapshot must exist
  echo "$line" | jq -e '.data.tokens_snapshot' >/dev/null \
    || { echo "tokens_snapshot missing from data" >&2; echo "$line" >&2; false; }
  # All leaf values in tokens_snapshot must be numbers
  local all_numeric
  all_numeric=$(echo "$line" | jq '[.data.tokens_snapshot | .. | scalars | type == "number"] | all')
  [ "$all_numeric" = "true" ] \
    || { echo "Non-numeric value found in tokens_snapshot" >&2; echo "$line" >&2; false; }
  # Specific field values
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 5000' >/dev/null
  echo "$line" | jq -e '.data.tokens_snapshot.output_tokens == 1200' >/dev/null
  echo "$line" | jq -e '.data.tokens_snapshot.cache_read_input_tokens == 800' >/dev/null
}

@test "payload data contains ONLY step_name and tokens_snapshot — no prompt or response text" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  run bash "$EMIT_HELPER" 1 load-story E998-S1 \
    --tokens '{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}'
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  # data object must have exactly 2 keys: step_name and tokens_snapshot
  local key_count
  key_count=$(echo "$line" | jq '.data | keys | length')
  [ "$key_count" -eq 2 ] \
    || { echo "Expected exactly 2 keys in data, got $key_count" >&2; echo "$line" | jq '.data | keys' >&2; false; }
  echo "$line" | jq -e '.data | has("step_name")' >/dev/null
  echo "$line" | jq -e '.data | has("tokens_snapshot")' >/dev/null
}

# ---------- Scenario E: backwards-compat ----------

@test "emit-step-boundary without --tokens produces event with no tokens_snapshot" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  run bash "$EMIT_HELPER" 1 load-story E998-S1
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/lifecycle-events.jsonl" ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  # event_type and step_name must be correct
  echo "$line" | jq -e '.event_type == "step_boundary"' >/dev/null
  echo "$line" | jq -e '.data.step_name == "load-story"' >/dev/null
  # tokens_snapshot must NOT be present
  local has_tokens
  has_tokens=$(echo "$line" | jq 'has("tokens_snapshot") or (.data | has("tokens_snapshot"))')
  [ "$has_tokens" = "false" ] \
    || { echo "tokens_snapshot should not be present without --tokens flag" >&2; echo "$line" >&2; false; }
  # data must have exactly 1 key: step_name
  local key_count
  key_count=$(echo "$line" | jq '.data | keys | length')
  [ "$key_count" -eq 1 ] \
    || { echo "Expected 1 key in data without --tokens, got $key_count" >&2; echo "$line" | jq '.data' >&2; false; }
}

# ---------- Scenario F: Privacy guard non-vacuity (AC4 hard guarantee) ----------

@test "PRIVACY: --tokens payload with a string value is REJECTED (tokens_snapshot omitted)" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  # Payload contains a string "sneaky" — this MUST be rejected
  run bash "$EMIT_HELPER" 1 load-story E998-S1 \
    --tokens '{"input_tokens":100,"sneaky":"prompt text that must never land"}'
  [ "$status" -eq 0 ]  # graceful-skip, not a hard failure
  [ -f "$TEST_TMP/lifecycle-events.jsonl" ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  # The event should still land (timing data preserved)
  echo "$line" | jq -e '.event_type == "step_boundary"' >/dev/null
  echo "$line" | jq -e '.data.step_name == "load-story"' >/dev/null
  # But tokens_snapshot must NOT be present (rejected due to string value)
  local has_tokens
  has_tokens=$(echo "$line" | jq '.data | has("tokens_snapshot")')
  [ "$has_tokens" = "false" ] \
    || { echo "PRIVACY VIOLATION: tokens_snapshot present despite string value in payload" >&2; echo "$line" >&2; false; }
  # Belt-and-suspenders: the smuggled string must not appear anywhere in the raw JSONL
  ! grep -qF "prompt text that must never land" "$TEST_TMP/lifecycle-events.jsonl" \
    || { echo "PRIVACY VIOLATION: smuggled string found in raw JSONL" >&2; cat "$TEST_TMP/lifecycle-events.jsonl" >&2; false; }
}

@test "PRIVACY: --tokens with nested string is rejected" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  run bash "$EMIT_HELPER" 1 load-story E998-S1 \
    --tokens '{"input_tokens":100,"output_tokens":50,"metadata":{"text":"should be rejected"}}'
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  local has_tokens
  has_tokens=$(echo "$line" | jq '.data | has("tokens_snapshot")')
  [ "$has_tokens" = "false" ] \
    || { echo "PRIVACY VIOLATION: tokens_snapshot present despite nested string" >&2; echo "$line" >&2; false; }
  # Belt-and-suspenders: nested string must not appear in raw JSONL
  ! grep -qF "should be rejected" "$TEST_TMP/lifecycle-events.jsonl" \
    || { echo "PRIVACY VIOLATION: nested string found in raw JSONL" >&2; cat "$TEST_TMP/lifecycle-events.jsonl" >&2; false; }
}

@test "PRIVACY: --tokens with invalid JSON is silently skipped" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  run bash "$EMIT_HELPER" 1 load-story E998-S1 \
    --tokens 'not-valid-json{{'
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  echo "$line" | jq -e '.event_type == "step_boundary"' >/dev/null
  local has_tokens
  has_tokens=$(echo "$line" | jq '.data | has("tokens_snapshot")')
  [ "$has_tokens" = "false" ] \
    || { echo "tokens_snapshot present despite invalid JSON" >&2; echo "$line" >&2; false; }
}

@test "PRIVACY: --tokens with array (not object) is rejected" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  run bash "$EMIT_HELPER" 1 load-story E998-S1 \
    --tokens '[100, 200]'
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  local has_tokens
  has_tokens=$(echo "$line" | jq '.data | has("tokens_snapshot")')
  [ "$has_tokens" = "false" ] \
    || { echo "tokens_snapshot present despite array payload (not object)" >&2; echo "$line" >&2; false; }
}

# ---------- Scenario G: Key-name smuggling (Fix-1 hardening) ----------

@test "PRIVACY: smuggled key name is REJECTED (key text never serialized)" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  # All VALUES are numeric, but one KEY carries arbitrary text — this MUST be rejected
  run bash "$EMIT_HELPER" 1 load-story E998-S1 \
    --tokens '{"prompt text here":1}'
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/lifecycle-events.jsonl" ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  # Event still lands (graceful-skip)
  echo "$line" | jq -e '.event_type == "step_boundary"' >/dev/null
  echo "$line" | jq -e '.data.step_name == "load-story"' >/dev/null
  # tokens_snapshot must be absent — the non-allowlisted key blocks the whole payload
  local has_tokens
  has_tokens=$(echo "$line" | jq '.data | has("tokens_snapshot")')
  [ "$has_tokens" = "false" ] \
    || { echo "PRIVACY VIOLATION: tokens_snapshot present despite smuggled key name" >&2; echo "$line" >&2; false; }
  # Belt-and-suspenders: the key text must not appear in the raw JSONL
  ! grep -qF "prompt text here" "$TEST_TMP/lifecycle-events.jsonl" \
    || { echo "PRIVACY VIOLATION: smuggled key text found in raw JSONL" >&2; cat "$TEST_TMP/lifecycle-events.jsonl" >&2; false; }
}

@test "PRIVACY: partial smuggled key mixed with valid keys is REJECTED" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  # Three valid keys + one non-allowlisted key — entire payload must be rejected
  run bash "$EMIT_HELPER" 1 load-story E998-S1 \
    --tokens '{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"evil key":4}'
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  local has_tokens
  has_tokens=$(echo "$line" | jq '.data | has("tokens_snapshot")')
  [ "$has_tokens" = "false" ] \
    || { echo "PRIVACY VIOLATION: tokens_snapshot present despite non-allowlisted key" >&2; echo "$line" >&2; false; }
  ! grep -qF "evil key" "$TEST_TMP/lifecycle-events.jsonl" \
    || { echo "PRIVACY VIOLATION: non-allowlisted key text in raw JSONL" >&2; cat "$TEST_TMP/lifecycle-events.jsonl" >&2; false; }
}

@test "PRIVACY: valid subset payload (2 of 4 allowlisted keys) is ACCEPTED" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  # Only input_tokens and output_tokens — valid subset of the allowlist
  run bash "$EMIT_HELPER" 1 load-story E998-S1 \
    --tokens '{"input_tokens":500,"output_tokens":200}'
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 500' >/dev/null \
    || { echo "Expected input_tokens=500 in accepted subset payload" >&2; echo "$line" >&2; false; }
  echo "$line" | jq -e '.data.tokens_snapshot.output_tokens == 200' >/dev/null \
    || { echo "Expected output_tokens=200 in accepted subset payload" >&2; echo "$line" >&2; false; }
}

# ---------- Scenario H: --tokens missing value (Fix-2 shift foot-gun) ----------

@test "tokens as last arg with no value degrades gracefully (no crash)" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  # --tokens is the last argument with no value following — must not crash
  run bash "$EMIT_HELPER" 1 load-story E998-S1 --tokens
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/lifecycle-events.jsonl" ]
  local line
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  # Event still lands with timing data
  echo "$line" | jq -e '.event_type == "step_boundary"' >/dev/null
  echo "$line" | jq -e '.data.step_name == "load-story"' >/dev/null
  # tokens_snapshot should not be present (missing value = graceful skip)
  local has_tokens
  has_tokens=$(echo "$line" | jq '.data | has("tokens_snapshot")')
  [ "$has_tokens" = "false" ] \
    || { echo "tokens_snapshot should not be present with missing --tokens value" >&2; echo "$line" >&2; false; }
}
