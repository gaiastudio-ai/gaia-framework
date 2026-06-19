#!/usr/bin/env bats
# e106-s3-agent-native-capacity-check.bats — E106-S3
#
# The SM "is this sprint too big" check, redefined on three agent-native
# measures (ADR-128): (1) dependency critical-path depth, (2) context-coherence
# ceiling (distinct story count), (3) measured agent wall-clock vs an
# agent-session budget — measure 3 telemetry-gated. The points-per-calendar-time
# heuristic that false-flagged the 73-point sprint-53 sweep is GONE (AC1).
# Cold start (no telemetry) uses only depth + coherence, no fabricated constant
# (AC4 / NFR-90).
#
# Maps to AC1-AC5, AC-INT1 and TS1-TS6.
# Refs: ADR-128, ADR-042, NFR-90, FR-552

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/sm-capacity-check.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/agent-native-capacity"
  # telemetry fixtures from E106-S1 (median minutes/story = 50)
  TELE_FIX="$BATS_TEST_DIRNAME/fixtures/throughput-telemetry"
  EVENTS_CAL="$TELE_FIX/lifecycle-events.jsonl"
  EVENTS_EMPTY="$BATS_TEST_DIRNAME/fixtures/dual-track-estimation/events-empty.jsonl"
  SPRINT_YAML="$TELE_FIX/sprint-status.yaml"
  # default thresholds used across tests
  DEPTH=5
  COH=15
  BUDGET=480
}

run_check() { # $1=stories file ; remaining args appended
  local sf="$1"; shift
  run bash "$SCRIPT" --stories-file "$sf" --depth-threshold "$DEPTH" \
    --coherence-ceiling "$COH" --session-budget-min "$BUDGET" "$@"
}

# ---------- AC1 / TS5: sprint-53 false-positive case must NOT flag ----------

@test "points-heavy (73pt) but coherent + shallow-dep batch is NOT flagged" {
  run_check "$FIX/sprint53-like.stories"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'capacity:[[:space:]]*ok|verdict:[[:space:]]*ok|not flagged|within' \
    || { echo "sprint-53-like batch should pass capacity, got:" >&2; echo "$output" >&2; false; }
}

@test "the points-per-duration heuristic is gone (no points-vs-duration verdict)" {
  run_check "$FIX/sprint53-like.stories"
  [ "$status" -eq 0 ]
  # must NOT reason about points-per-time, velocity floors, or "too many points"
  ! echo "$output" | grep -Eiq 'points per (day|week|month|duration)|too many points|points.*too much|velocity.*floor|points.*sprint|pt.*wk|throughput.*point' \
    || { echo "must not use points-per-duration/velocity-floor heuristic, got:" >&2; echo "$output" >&2; false; }
}

# ---------- AC2 / TS3: dependency critical-path depth ----------

@test "deep dependency chain is flagged regardless of low point-sum" {
  # 7-deep serial chain, 14 points total -> exceeds depth-threshold 5
  run_check "$FIX/deep-chain.stories"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'depth|critical.path|chain' \
    || { echo "expected a depth measure, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eiq 'flag|exceed|over' \
    || { echo "deep chain should be flagged, got:" >&2; echo "$output" >&2; false; }
}

@test "json reports the computed critical-path depth" {
  run_check "$FIX/deep-chain.stories" --json
  [ "$status" -eq 0 ]
  # 7-node serial chain -> depth 7
  echo "$output" | jq -e '.critical_path_depth == 7' >/dev/null
  echo "$output" | jq -e '.depth_flagged == true' >/dev/null
}

# ---------- AC3 / TS4: context-coherence ceiling ----------

@test "coherence-exceeding batch is flagged even at modest points" {
  # 20 distinct stories, 20 points, shallow deps -> exceeds coherence-ceiling 15
  run_check "$FIX/wide-batch.stories"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'coherence' \
    || { echo "expected a coherence measure, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eiq 'flag|exceed|over' \
    || { echo "wide batch should be flagged, got:" >&2; echo "$output" >&2; false; }
}

@test "json reports distinct-story coherence count" {
  run_check "$FIX/wide-batch.stories" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.coherence_count == 20' >/dev/null
  echo "$output" | jq -e '.coherence_flagged == true' >/dev/null
}

@test "sprint-53-like clears while wide-batch flags (the measure swap)" {
  run_check "$FIX/sprint53-like.stories" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.flagged == false' >/dev/null
  run_check "$FIX/wide-batch.stories" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.flagged == true' >/dev/null
}

# ---------- AC4 / TS1: cold-start (no telemetry) ----------

@test "cold-start uses depth+coherence only, no fabricated constant" {
  run bash "$SCRIPT" --stories-file "$FIX/sprint53-like.stories" \
    --depth-threshold "$DEPTH" --coherence-ceiling "$COH" --session-budget-min "$BUDGET" \
    --events "$EVENTS_EMPTY" --sprint-yaml "$SPRINT_YAML" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.wall_clock_measure == "uncalibrated"' >/dev/null
  echo "$output" | jq -e '.wall_clock_minutes == null' >/dev/null
  # depth + coherence still computed
  echo "$output" | jq -e '.critical_path_depth != null' >/dev/null
  echo "$output" | jq -e '.coherence_count != null' >/dev/null
}

@test "cold-start emits NO fabricated wall-clock number" {
  run bash "$SCRIPT" --stories-file "$FIX/sprint53-like.stories" \
    --depth-threshold "$DEPTH" --coherence-ceiling "$COH" --session-budget-min "$BUDGET" \
    --events "$EVENTS_EMPTY" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  wc_line=$(echo "$output" | grep -i 'wall.clock' || true)
  echo "$wc_line" | grep -Eiq 'uncalibrated'
}

# ---------- AC4 / TS2: warm (all three measures) ----------

@test "warm path adds measured wall-clock vs session budget" {
  run bash "$SCRIPT" --stories-file "$FIX/sprint53-like.stories" \
    --depth-threshold "$DEPTH" --coherence-ceiling "$COH" --session-budget-min "$BUDGET" \
    --events "$EVENTS_CAL" --sprint-yaml "$SPRINT_YAML" --json
  [ "$status" -eq 0 ]
  # median minutes/story = 50 ; 11 stories -> 550 min vs budget 480 -> over budget
  echo "$output" | jq -e '.wall_clock_minutes == 550' >/dev/null
  echo "$output" | jq -e '.wall_clock_measure != "uncalibrated"' >/dev/null
  # 550 > 480 budget -> the wall-clock measure must flag
  echo "$output" | jq -e '.wall_clock_flagged == true' >/dev/null
}

# ---------- robustness ----------

@test "missing --stories-file fails with usage error" {
  run bash "$SCRIPT" --depth-threshold 5 --coherence-ceiling 15
  [ "$status" -ne 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'capacity'
}

# ---------- AC-INT1 / TS6: sprint-plan wiring present ----------

@test "sprint-plan SKILL.md references the agent-native capacity check" {
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-sprint-plan/SKILL.md"
  [ -f "$SKILL" ]
  grep -Eiq 'sm-capacity-check|agent-native (capacity|measures)|critical-path depth|coherence ceiling' "$SKILL"
}

@test "sm.md capacity authority references agent-native measures" {
  SM="$REPO_ROOT/plugins/gaia/agents/sm.md"
  [ -f "$SM" ]
  grep -Eiq 'agent-native|critical-path depth|coherence ceiling|sm-capacity-check' "$SM"
}
