#!/usr/bin/env bats
# observability-hardening.bats — report consistency, escaping, sort, and
# coverage backfill for the observability scripts.
#
# Fixture directory: tests/fixtures/observability-hardening/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STEP_REPORT="$REPO_ROOT/plugins/gaia/scripts/step-report.sh"
  THROUGHPUT="$REPO_ROOT/plugins/gaia/scripts/throughput-telemetry.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/observability-hardening"

  TEST_TMP="$BATS_TEST_TMPDIR/oh-$$"
  mkdir -p "$TEST_TMP"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ==========================================================================
# AC1: text/JSON n/a consistency — all-negative-diff renders n/a in BOTH modes
# ==========================================================================

@test "all-negative-diff story renders n/a total tokens in JSON mode" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/all-negative-diff.jsonl" --json
  [ "$status" -eq 0 ]
  total_tok=$(echo "$output" | jq -r '.stories[0].total_tokens_approx')
  [ "$total_tok" = "null" ] \
    || { echo "Expected null total_tokens_approx for all-negative-diff, got: $total_tok" >&2; false; }
}

@test "all-negative-diff story renders n/a total tokens in text mode" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/all-negative-diff.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'Total token estimate.*n/a' \
    || { echo "Expected 'Total token estimate: n/a' for all-negative-diff, got:" >&2; echo "$output" >&2; false; }
  # Must NOT contain ~0 tok
  ! echo "$output" | grep -qF '~0 tok' \
    || { echo "Found '~0 tok' in all-negative-diff output (bug)" >&2; echo "$output" >&2; false; }
}

@test "all-negative-diff throughput step-durations renders all per-field n/a" {
  run bash "$THROUGHPUT" --events "$FIXTURE_DIR/all-negative-diff.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Both step lines should have all four fields as n/a (all diffs negative, but
  # token snapshots are present so the per-field form is used, not collapsed n/a)
  printf '%s\n' "$output" | grep "NEG-S1" | grep "step 1" | grep -qF "input: n/a" \
    || { echo "Expected 'input: n/a' for all-negative-diff step 1" >&2; echo "$output" >&2; false; }
  printf '%s\n' "$output" | grep "NEG-S1" | grep "step 1" | grep -qF "output: n/a" \
    || { echo "Expected 'output: n/a' for all-negative-diff step 1" >&2; echo "$output" >&2; false; }
  # Must not show any approximate token numbers (all fields are negative -> n/a)
  ! printf '%s\n' "$output" | grep "NEG-S1" | grep -qE '~[0-9]+ tok' \
    || { echo "Unexpected approximate token counts for all-negative-diff" >&2; echo "$output" >&2; false; }
}

# ==========================================================================
# AC2: grep escaping — ERE metacharacters in story keys must not cross-match
# ==========================================================================

@test "story key with ERE metachar does not cross-match (text mode)" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/ere-metachar.jsonl" --story "E1-S1"
  [ "$status" -eq 0 ]
  # Must contain E1-S1 data
  echo "$output" | grep -qF 'E1-S1' \
    || { echo "Expected E1-S1 in filtered output" >&2; echo "$output" >&2; false; }
  # Must NOT contain E+1-S1 data
  ! echo "$output" | grep -qF 'E+1-S1' \
    || { echo "E+1-S1 cross-matched into E1-S1 filter (ERE escaping bug)" >&2; echo "$output" >&2; false; }
}

@test "story key with ERE metachar does not cross-match (JSON mode)" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/ere-metachar.jsonl" --story "E1-S1" --json
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq '.stories | length')
  [ "$count" -eq 1 ] \
    || { echo "Expected 1 story, got $count (ERE cross-match?)" >&2; echo "$output" >&2; false; }
  key=$(echo "$output" | jq -r '.stories[0].story_key')
  [ "$key" = "E1-S1" ] \
    || { echo "Expected story_key E1-S1, got $key" >&2; false; }
}

@test "text-mode display row matches its story section (no ERE cross-match)" {
  # Run the full report (no --story filter) to exercise the grep at the
  # text-mode display loop. E+1-S1 in ERE matches "E" followed by one-or-more
  # of any char, then "1-S1" — so grep -E "^E+1-S1\t" matches E1-S1 too.
  # The fix replaces the unescaped grep with awk exact-match.
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/ere-metachar.jsonl"
  [ "$status" -eq 0 ]
  # E+1-S1's step row must show 10 min (its own data), not 5 min (E1-S1's data)
  # E+1-S1: step1 at t=10, step2 at t=20 => 10 min
  eplus_section=$(echo "$output" | awk '/Story: E[+]1-S1/{found=1} found && /^Story: E1-S1/{exit} found{print}')
  echo "$eplus_section" | grep -Eq 'load-story.*10 min' \
    || { echo "E+1-S1 step row should show 10 min (own data), section:" >&2; echo "$eplus_section" >&2; false; }
}

# ==========================================================================
# AC4: telemetry sort — out-of-order events are sorted correctly
# ==========================================================================

@test "out-of-order step events produce sorted step-duration output" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/out-of-order.jsonl" --json
  [ "$status" -eq 0 ]
  # Steps must be in ascending order: 1, 2, 3
  s1=$(echo "$output" | jq '.stories[0].steps[0].step')
  s2=$(echo "$output" | jq '.stories[0].steps[1].step')
  s3=$(echo "$output" | jq '.stories[0].steps[2].step')
  [ "$s1" -eq 1 ]
  [ "$s2" -eq 2 ]
  [ "$s3" -eq 3 ]
  # Durations: step1(t=0)->step2(t=5)=5, step2(t=5)->step3(t=10)=5, step3(t=10)->step4(t=20)=10
  d1=$(echo "$output" | jq '.stories[0].steps[0].duration_min')
  d2=$(echo "$output" | jq '.stories[0].steps[1].duration_min')
  d3=$(echo "$output" | jq '.stories[0].steps[2].duration_min')
  [ "$d1" -eq 5 ]
  [ "$d2" -eq 5 ]
  [ "$d3" -eq 10 ]
}

@test "out-of-order throughput step-durations produce sorted output" {
  run bash "$THROUGHPUT" --events "$FIXTURE_DIR/out-of-order.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Steps must appear in ascending order
  local steps
  steps=$(printf '%s\n' "$output" | grep 'OOO-S1.*step' | sed -E 's/.*step[[:space:]]+([0-9]+).*/\1/' | tr '\n' ' ')
  local prev=0
  for s in $steps; do
    [ "$s" -gt "$prev" ] || { echo "Steps not ascending: prev=$prev, cur=$s" >&2; false; }
    prev=$s
  done
}

# ==========================================================================
# AC5: coverage backfill tests
# ==========================================================================

# --- empty events for --step-durations ---
@test "step-durations with empty events file produces (none)" {
  : > "$TEST_TMP/empty.jsonl"
  run bash "$THROUGHPUT" --events "$TEST_TMP/empty.jsonl" --step-durations
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '(none)' \
    || { echo "Expected (none) for empty events step-durations" >&2; echo "$output" >&2; false; }
}

# --- multi-story interleaving ---
@test "multi-story interleaving produces correct per-story data (step-report)" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/multi-story-interleaved.jsonl" --json
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq '.stories | length')
  [ "$count" -eq 2 ] \
    || { echo "Expected 2 stories, got $count" >&2; echo "$output" >&2; false; }
  # INT-S1: step1(t=0)->step2(t=5) = 5min
  s1_dur=$(echo "$output" | jq '[.stories[] | select(.story_key=="INT-S1")][0].steps[0].duration_min')
  [ "$s1_dur" -eq 5 ] \
    || { echo "Expected INT-S1 step 1 duration=5, got $s1_dur" >&2; false; }
  # INT-S2: step1(t=2)->step2(t=8) = 6min
  s2_dur=$(echo "$output" | jq '[.stories[] | select(.story_key=="INT-S2")][0].steps[0].duration_min')
  [ "$s2_dur" -eq 6 ] \
    || { echo "Expected INT-S2 step 1 duration=6, got $s2_dur" >&2; false; }
}

# --- step_boundary missing step number ---
@test "step_boundary with missing step number does not crash" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/missing-step-number.jsonl" --json
  [ "$status" -eq 0 ]
  # The event with no step number gets step=null from jq, which awk coerces to 0.
  # So we get steps 0, 1, 3 -> diffs for 0->1 and 1->3. The script must not crash
  # and must produce a valid JSON structure.
  echo "$output" | jq -e '.' >/dev/null \
    || { echo "Invalid JSON output for missing-step-number fixture" >&2; false; }
  # At least 1 story should be present
  count=$(echo "$output" | jq '.stories | length')
  [ "$count" -ge 1 ] \
    || { echo "Expected at least 1 story, got $count" >&2; echo "$output" >&2; false; }
}

# --- cache_* field diffs value-pinned ---
@test "cache field diffs are value-pinned to exact expected values" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/cache-field-diffs.jsonl" --json
  [ "$status" -eq 0 ]
  # Step 1->2: cache_creation = 350-100=250, cache_read = 700-200=500
  cc1=$(echo "$output" | jq '.stories[0].steps[0].tokens.cache_creation_input_tokens')
  cr1=$(echo "$output" | jq '.stories[0].steps[0].tokens.cache_read_input_tokens')
  [ "$cc1" -eq 250 ] || { echo "Expected cache_creation=250 for step 1, got $cc1" >&2; false; }
  [ "$cr1" -eq 500 ] || { echo "Expected cache_read=500 for step 1, got $cr1" >&2; false; }
  # Step 2->3: cache_creation = 600-350=250, cache_read = 1200-700=500
  cc2=$(echo "$output" | jq '.stories[0].steps[1].tokens.cache_creation_input_tokens')
  cr2=$(echo "$output" | jq '.stories[0].steps[1].tokens.cache_read_input_tokens')
  [ "$cc2" -eq 250 ] || { echo "Expected cache_creation=250 for step 2, got $cc2" >&2; false; }
  [ "$cr2" -eq 500 ] || { echo "Expected cache_read=500 for step 2, got $cr2" >&2; false; }
}

# --- mixed-presence (tokens on step N, absent N+1) ---
@test "mixed-presence tokens render correctly (step report)" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/mixed-presence.jsonl" --json
  [ "$status" -eq 0 ]
  # Step 1->2: both have tokens -> real diff
  s1_tok=$(echo "$output" | jq '.stories[0].steps[0].tokens')
  [ "$s1_tok" != "null" ] || { echo "Expected tokens for step 1 (both present), got null" >&2; false; }
  # Step 2->3: step 3 has no tokens -> null
  s2_tok=$(echo "$output" | jq '.stories[0].steps[1].tokens')
  [ "$s2_tok" = "null" ] || { echo "Expected null for step 2 (next has no tokens), got $s2_tok" >&2; false; }
}

# --- single-step story ---
@test "single-step story produces empty steps array (no diff possible)" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/single-step.jsonl" --json
  [ "$status" -eq 0 ]
  # A single step cannot be differenced, so the story has zero measured steps
  count=$(echo "$output" | jq '.stories | length')
  [ "$count" -eq 0 ] \
    || { echo "Expected 0 stories for single-step (no diff), got $count" >&2; echo "$output" >&2; false; }
}

# --- all-tokens-missing -> null total ---
@test "all-tokens-missing story renders null total tokens in JSON" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/all-tokens-missing.jsonl" --json
  [ "$status" -eq 0 ]
  total_tok=$(echo "$output" | jq -r '.stories[0].total_tokens_approx')
  [ "$total_tok" = "null" ] \
    || { echo "Expected null total_tokens_approx for all-missing, got: $total_tok" >&2; false; }
}

@test "all-tokens-missing story renders n/a in text mode" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/all-tokens-missing.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'Total token estimate.*n/a' \
    || { echo "Expected 'Total token estimate: n/a' for all-missing, got:" >&2; echo "$output" >&2; false; }
}

# --- --story unknown-key ---
@test "story with unknown key produces empty output" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/cache-field-diffs.jsonl" --story "NOPE-S99" --json
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq '.stories | length')
  [ "$count" -eq 0 ] \
    || { echo "Expected 0 stories for unknown key, got $count" >&2; echo "$output" >&2; false; }
}

@test "story unknown-key text mode produces no-events message" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/cache-field-diffs.jsonl" --story "NOPE-S99"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'no step_boundary events found' \
    || { echo "Expected no-events message for unknown key" >&2; echo "$output" >&2; false; }
}

# --- JSON-vs-text numeric parity cross-check ---
@test "JSON and text mode duration totals match (parity cross-check)" {
  # Use the cache-field-diffs fixture: 2 steps, durations 5+5=10
  local json_out text_out
  json_out=$(bash "$STEP_REPORT" --events "$FIXTURE_DIR/cache-field-diffs.jsonl" --json)
  text_out=$(bash "$STEP_REPORT" --events "$FIXTURE_DIR/cache-field-diffs.jsonl")
  json_total=$(echo "$json_out" | jq '.stories[0].total_duration_min')
  text_total=$(echo "$text_out" | grep -Eo 'Total wall-clock: [0-9]+' | grep -Eo '[0-9]+')
  [ "$json_total" -eq "$text_total" ] \
    || { echo "Duration parity mismatch: JSON=$json_total, text=$text_total" >&2; false; }
}

@test "JSON and text mode token totals match (parity cross-check)" {
  local json_out text_out
  json_out=$(bash "$STEP_REPORT" --events "$FIXTURE_DIR/cache-field-diffs.jsonl" --json)
  text_out=$(bash "$STEP_REPORT" --events "$FIXTURE_DIR/cache-field-diffs.jsonl")
  json_input=$(echo "$json_out" | jq '.stories[0].total_tokens_approx.input_tokens')
  # Text mode total: "~N tok input" — extract N
  text_input=$(echo "$text_out" | grep 'Total token' | grep -Eo '~[0-9]+ tok input' | grep -Eo '[0-9]+')
  [ "$json_input" -eq "$text_input" ] \
    || { echo "Token parity mismatch: JSON=$json_input, text=$text_input" >&2; false; }
}

# --- full output-line format golden for step-report text ---
@test "step-report text output-line format matches golden structure" {
  run bash "$STEP_REPORT" --events "$FIXTURE_DIR/cache-field-diffs.jsonl"
  [ "$status" -eq 0 ]
  # Header line
  echo "$output" | grep -qF 'step-report' || { echo "Missing header" >&2; false; }
  # Story header
  echo "$output" | grep -qF 'Story: CFD-S1' || { echo "Missing story header" >&2; false; }
  # Column header
  echo "$output" | grep -qF 'Step' && echo "$output" | grep -qF 'Name' && echo "$output" | grep -qF 'Duration'
  # Step rows with format: step number, name, duration, token fields
  echo "$output" | grep -Eq '1[[:space:]]+load-story[[:space:]]+5 min'
  # Total lines
  echo "$output" | grep -qF 'Total wall-clock:'
  echo "$output" | grep -qF 'Total token estimate:'
}
