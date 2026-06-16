#!/usr/bin/env bats
# step-boundary-telemetry.bats — per-step timing instrumentation tests
#
# Covers the step_boundary lifecycle event emission and the throughput-telemetry
# derivation path that differences consecutive same-story step events into
# per-step wall-clock durations.
#
# Four test scenarios:
#   1. 16-boundary emission (fixture count)
#   2. Two consecutive step events -> correct duration difference
#   3. state_transition-only fixture -> byte-stable output (no regression)
#   4. Duplicate boundary -> no negative or double-counted duration
#
# Plus: SKILL.md instrumentation verification (all 16 steps have emission
# directives) and out-of-scope sub-step documentation.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/throughput-telemetry.sh"
  SKILL_MD="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/SKILL.md"
  EMIT_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/scripts/emit-step-boundary.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/step-boundary-telemetry"

  TEST_TMP="$BATS_TEST_TMPDIR/sb-$$"
  mkdir -p "$TEST_TMP"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ---------- Scenario 1: 16-boundary emission ----------

@test "AC1/AC2: fixture with 16 step_boundary events contains exactly 16 events" {
  count=$(grep -c '"event_type":"step_boundary"' "$FIXTURE_DIR/sixteen-steps.jsonl")
  [ "$count" -eq 16 ]
}

@test "AC2: SKILL.md contains an emit-step-boundary directive for each of the 16 principal steps" {
  for step_num in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    grep -qE "emit-step-boundary\.sh[[:space:]]+${step_num}[[:space:]]" "$SKILL_MD" \
      || { echo "Missing emit-step-boundary directive for step $step_num" >&2; false; }
  done
}

@test "AC2: SKILL.md documents 9 lettered sub-steps as out of scope for v1" {
  grep -q 'out of scope for v1' "$SKILL_MD" \
    || { echo "Missing out-of-scope sub-step documentation" >&2; false; }
  # All 9 sub-steps must be listed
  scope_line=$(grep 'out of scope for v1' "$SKILL_MD")
  for sub in 2a 2b 3b 5a 6a 6b 7a 7b 14b; do
    echo "$scope_line" | grep -qF "$sub" \
      || { echo "Missing sub-step $sub in out-of-scope documentation" >&2; false; }
  done
}

@test "AC1: emit-step-boundary helper script exists and is executable" {
  [ -f "$EMIT_HELPER" ]
  [ -x "$EMIT_HELPER" ]
}

@test "AC1: emit-step-boundary helper invokes lifecycle-event.sh with step_boundary type" {
  grep -qF 'step_boundary' "$EMIT_HELPER"
  grep -qF 'lifecycle-event.sh' "$EMIT_HELPER"
}

# ---------- Scenario 2: per-step duration derivation ----------

@test "AC3: two consecutive step events yield correct 5-minute duration" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/two-steps.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Step 1 -> Step 2 is 5 minutes. Match with a literal tab after the step
  # number so "step 1" cannot match "step 10" or "step 11" (F-2 precision fix).
  local tab=$'\t'
  printf '%s\n' "$output" | grep -qF "step 1${tab}5 min" \
    || { echo "Expected step 1 duration of 5 min, got:" >&2; echo "$output" >&2; false; }
}

@test "AC3: sixteen-step fixture derives 15 durations (last step is open-ended)" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/sixteen-steps.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Count duration lines for E950-S1 (should be 15, steps 1-15 each have a next)
  dur_count=$(printf '%s\n' "$output" | grep 'E950-S1.*step' | wc -l | tr -d ' ')
  [ "$dur_count" -eq 15 ] \
    || { echo "Expected 15 step-duration lines, got $dur_count:" >&2; echo "$output" >&2; false; }
}

@test "AC3: step durations are ordered by (story_key, step)" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/sixteen-steps.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Extract step numbers in order, verify they are ascending
  steps=$(echo "$output" | grep 'E950-S1.*step' | sed -E 's/.*step[[:space:]]+([0-9]+).*/\1/' | tr '\n' ' ')
  prev=0
  for s in $steps; do
    [ "$s" -gt "$prev" ] || { echo "Steps not ascending: prev=$prev, cur=$s" >&2; false; }
    prev=$s
  done
}

# ---------- Scenario 3: state_transition byte-stability ----------

@test "AC4: state_transition-only fixture produces byte-identical output (text)" {
  # Full byte-comparison of the derivation body (skip the first 2 header lines
  # which contain absolute paths that vary per host). The expected body is the
  # golden output frozen at the time the step_boundary feature landed.
  local body
  body=$(bash "$SCRIPT" \
    --events "$FIXTURE_DIR/state-transition-only.jsonl" \
    --sprint-yaml "$FIXTURE_DIR/sprint-status.yaml" | tail -n +3)
  local tab=$'\t'
  local expected
  expected=$(cat <<EOF

median_minutes_per_story: 50
median_minutes_per_point: 20
stories_counted: 2

Per-story wall-clock:
  E900-S1${tab}40 min${tab}4 pts${tab}10 min/pt
  E900-S2${tab}60 min${tab}2 pts${tab}30 min/pt

Skipped (recorded notes):
  E900-S3${tab}skip: insufficient transitions (count=1) — note recorded
EOF
)
  [ "$body" = "$expected" ] \
    || { echo "Text output body is NOT byte-identical to golden:" >&2
         diff <(printf '%s\n' "$expected") <(printf '%s\n' "$body") >&2; false; }
}

@test "AC4: state_transition-only fixture produces byte-identical output (json)" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  local actual
  actual=$(bash "$SCRIPT" \
    --events "$FIXTURE_DIR/state-transition-only.jsonl" \
    --sprint-yaml "$FIXTURE_DIR/sprint-status.yaml" --json)
  # Golden JSON output — the exact bytes jq -n produces for these values.
  local expected='{"median_minutes_per_story":50,"median_minutes_per_point":20,"stories_counted":2}'
  # Normalize both through jq -Sc for deterministic key-order comparison.
  local norm_actual norm_expected
  norm_actual=$(printf '%s' "$actual" | jq -Sc '.')
  norm_expected=$(printf '%s' "$expected" | jq -Sc '.')
  [ "$norm_actual" = "$norm_expected" ] \
    || { echo "JSON output is NOT byte-identical to golden:" >&2
         echo "expected: $norm_expected" >&2
         echo "actual:   $norm_actual" >&2; false; }
}

@test "AC4: step_boundary events in fixture do not affect state_transition derivation" {
  # Mix step_boundary and state_transition events
  cat "$FIXTURE_DIR/state-transition-only.jsonl" "$FIXTURE_DIR/sixteen-steps.jsonl" \
    > "$TEST_TMP/mixed.jsonl"
  # Compare only the derivation body (skip the first header line which includes the filename)
  baseline=$(bash "$SCRIPT" \
    --events "$FIXTURE_DIR/state-transition-only.jsonl" \
    --sprint-yaml "$FIXTURE_DIR/sprint-status.yaml" | tail -n +2)
  mixed=$(bash "$SCRIPT" \
    --events "$TEST_TMP/mixed.jsonl" \
    --sprint-yaml "$FIXTURE_DIR/sprint-status.yaml" | tail -n +2)
  [ "$baseline" = "$mixed" ] \
    || { echo "Mixed events changed state_transition output:" >&2; diff <(echo "$baseline") <(echo "$mixed") >&2; false; }
}

# ---------- Scenario 4: duplicate/self boundary ----------

@test "AC4: duplicate step boundary does not produce negative duration" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/duplicate-step.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # No negative durations should appear
  ! echo "$output" | grep -Eq '\-[0-9]+ min' \
    || { echo "Negative duration found:" >&2; echo "$output" >&2; false; }
}

@test "AC4: duplicate step boundary does not double-count" {
  run bash "$SCRIPT" --events "$FIXTURE_DIR/duplicate-step.jsonl" --step-durations
  [ "$status" -eq 0 ]
  # Fixture: step 1 at t=0 and t=5 (duplicate), step 2 at t=10.
  # Dedup contract: keep FIRST occurrence of each step.
  # Expected: exactly 1 duration line — step 1 (first at t=0) -> step 2 (t=10) = 10 min.
  local tab=$'\t'
  local dur_lines
  dur_lines=$(printf '%s\n' "$output" | grep "E952-S1.*step")
  local dur_count
  dur_count=$(printf '%s\n' "$dur_lines" | grep '.' | wc -l | tr -d ' ')
  [ "$dur_count" -eq 1 ] \
    || { echo "Expected exactly 1 duration line, got $dur_count:" >&2; echo "$dur_lines" >&2; false; }
  # Assert the value is 10 min (first-occurrence difference), not 5 min (second).
  printf '%s\n' "$dur_lines" | grep -qF "step 1${tab}10 min" \
    || { echo "Expected step 1 = 10 min (first-occurrence diff), got:" >&2; echo "$dur_lines" >&2; false; }
}

# ---------- emit-step-boundary.sh contract ----------

@test "emit-step-boundary.sh emits a valid step_boundary event to jsonl" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP"
  run bash "$EMIT_HELPER" 1 load-story E999-S1
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/lifecycle-events.jsonl" ]
  line=$(cat "$TEST_TMP/lifecycle-events.jsonl")
  echo "$line" | jq -e '.event_type == "step_boundary"' >/dev/null
  echo "$line" | jq -e '.step == 1' >/dev/null
  echo "$line" | jq -e '.data.step_name == "load-story"' >/dev/null
  echo "$line" | jq -e '.story_key == "E999-S1"' >/dev/null
}

@test "emit-step-boundary.sh fails with usage error when args missing" {
  run bash "$EMIT_HELPER"
  [ "$status" -ne 0 ]
}

# ---------- SKILL.md anchor preservation ----------

@test "SKILL.md HTML-comment anchors are preserved after instrumentation" {
  # Verify all known load-bearing anchors still exist
  grep -qF '<!-- step1 script-wiring begin -->' "$SKILL_MD"
  grep -qF '<!-- step1 script-wiring end -->' "$SKILL_MD"
  grep -qF '<!-- step 2b atdd gate begin -->' "$SKILL_MD"
  grep -qF '<!-- step 2b atdd gate end -->' "$SKILL_MD"
  grep -qF '<!-- figma graceful-degrade begin -->' "$SKILL_MD"
  grep -qF '<!-- figma graceful-degrade end -->' "$SKILL_MD"
  grep -qF '<!-- planning gate begin -->' "$SKILL_MD"
  grep -qF '<!-- planning gate end -->' "$SKILL_MD"
  grep -qF '<!-- step5 tdd-review-gate begin -->' "$SKILL_MD"
  grep -qF '<!-- step5 tdd-review-gate end -->' "$SKILL_MD"
  grep -qF '<!-- step6 tdd-review-gate begin -->' "$SKILL_MD"
  grep -qF '<!-- step6 tdd-review-gate end -->' "$SKILL_MD"
  grep -qF '<!-- step 6b begin -->' "$SKILL_MD"
  grep -qF '<!-- step 6b end -->' "$SKILL_MD"
  grep -qF '<!-- step7 tdd-review-gate begin -->' "$SKILL_MD"
  grep -qF '<!-- step7 tdd-review-gate end -->' "$SKILL_MD"
  grep -qF '<!-- step 7b begin -->' "$SKILL_MD"
  grep -qF '<!-- step 7b end -->' "$SKILL_MD"
  grep -qF '<!-- step 9 dod-check wire begin -->' "$SKILL_MD"
  grep -qF '<!-- step 9 dod-check wire end -->' "$SKILL_MD"
  grep -qF '<!-- step 10 git-push wire begin -->' "$SKILL_MD"
  grep -qF '<!-- step 10 git-push wire end -->' "$SKILL_MD"
  grep -qF '<!-- step10 script-wiring begin -->' "$SKILL_MD"
  grep -qF '<!-- step10 script-wiring end -->' "$SKILL_MD"
  grep -qF '<!-- step 11a forbidden-sentinel scan begin -->' "$SKILL_MD"
  grep -qF '<!-- step 11a forbidden-sentinel scan end -->' "$SKILL_MD"
  grep -qF '<!-- step11 script-wiring begin -->' "$SKILL_MD"
  grep -qF '<!-- step11 script-wiring end -->' "$SKILL_MD"
  grep -qF '<!-- step 15 init-review-gate wire begin -->' "$SKILL_MD"
  grep -qF '<!-- step 15 init-review-gate wire end -->' "$SKILL_MD"
  grep -qF '<!-- step 16 begin -->' "$SKILL_MD"
  grep -qF '<!-- step 16 end -->' "$SKILL_MD"
  grep -qF '<!-- step 14b cache-refresh advisory begin -->' "$SKILL_MD"
  grep -qF '<!-- step 14b cache-refresh advisory end -->' "$SKILL_MD"
}
