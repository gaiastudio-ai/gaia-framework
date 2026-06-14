#!/usr/bin/env bats
# Sweep/facet sprint-shape detector coverage.
#
# The detector is a pure, read-only predicate consumed by /gaia-sprint-plan at
# commit time. It decides — from the committed story selection and the final
# goal count ALONE (no closed-sprint telemetry) — whether a sprint is
# sweep-shaped (goals map 1:1 to single stories) or facet-decomposed (one epic
# split into serial facets), and therefore whether the planner should stamp
# the completion-pass shape so the review-time incidental-goal floor relaxes.
#
# Cold-start invariant: the predicate resolves using only the story keys
# (epic membership derived from the E<n>-S<n> key) plus the goal count; it
# never reads sprint history or velocity telemetry.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
DETECT="$PLUGIN_DIR/scripts/detect-sweep-shape.sh"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# 1:1 sweep — goal count equals story count → stamp completion-pass.
# ---------------------------------------------------------------------------
@test "1:1 sweep: 5 goals mapping to 5 single stories stamps completion-pass" {
  run bash "$DETECT" --stories "E10-S1,E11-S2,E12-S3,E13-S4,E14-S5" --goals 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"completion-pass"* ]]
}

@test "1:1 sweep: two goals mapping to two single stories stamps completion-pass" {
  run bash "$DETECT" --stories "E20-S1,E21-S2" --goals 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"completion-pass"* ]]
}

# ---------------------------------------------------------------------------
# Single-epic facet decomposition — all stories share one epic → stamp.
# ---------------------------------------------------------------------------
@test "facet decomposition: three stories of one epic under two goals stamps completion-pass" {
  run bash "$DETECT" --stories "E30-S1,E30-S2,E30-S3" --goals 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"completion-pass"* ]]
}

# ---------------------------------------------------------------------------
# Multi-story outcome sprint — NOT sweep, NOT single-epic → no stamp.
# ---------------------------------------------------------------------------
@test "multi-story outcome: two goals each spanning three stories across epics is NOT stamped" {
  run bash "$DETECT" --stories "E40-S1,E40-S2,E40-S3,E41-S4,E41-S5,E41-S6" --goals 2
  [ "$status" -ne 0 ]
  [[ "$output" != *"completion-pass"* ]]
}

@test "multi-story outcome: a no-stamp verdict exits non-zero and prints nothing on stdout" {
  run bash "$DETECT" --stories "E40-S1,E40-S2,E40-S3,E41-S4,E41-S5,E41-S6" --goals 2
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Conservatism — a single story is not a sprint shape worth stamping.
# ---------------------------------------------------------------------------
@test "conservative: a single-story selection is not stamped" {
  run bash "$DETECT" --stories "E50-S1" --goals 1
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Cold-start invariant — the predicate needs no telemetry, only keys + goals.
# A run with a deliberately empty PROJECT_PATH (no sprint history reachable)
# still resolves the sweep shape from the arguments alone.
# ---------------------------------------------------------------------------
@test "cold start: sweep resolves from keys and goal count with no telemetry reachable" {
  export PROJECT_PATH="$TEST_TMP/empty-no-history"
  mkdir -p "$PROJECT_PATH"
  run bash "$DETECT" --stories "E60-S1,E61-S2,E62-S3" --goals 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"completion-pass"* ]]
}

# ---------------------------------------------------------------------------
# Argument hygiene — missing required args fail loudly, not silently stamp.
# ---------------------------------------------------------------------------
@test "missing --stories fails with non-zero status" {
  run bash "$DETECT" --goals 3
  [ "$status" -ne 0 ]
}

@test "missing --goals fails with non-zero status" {
  run bash "$DETECT" --stories "E70-S1,E71-S2"
  [ "$status" -ne 0 ]
}

@test "--help exits zero and documents the predicate" {
  run bash "$DETECT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"completion-pass"* ]]
}
