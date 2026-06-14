#!/usr/bin/env bats
# Sprint-review incidental-goal / velocity-distribution floor is SKIPPED on a
# completion-pass sprint.
#
# This proves the plan-time stamp actually engages the review-time tolerance:
# the SAME below-floor goal distribution produces a HIGH finding under the
# default (thrust) shape, but is downgraded to advisory-only (no HIGH, plus the
# rubric-applicability advisory) once the sprint carries completion-pass — the
# value the sweep/facet detector stamps at planning time.
#
# The deterministic floor evaluator is reused as-is; this story does not change
# the floor formula, only confirms the floor-skip wiring under the stamped shape.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
EVAL_SCRIPT="$PLUGIN_DIR/scripts/rubric-evaluate.sh"
RUBRIC="$PLUGIN_DIR/rubrics/base/sprint-review.json"

setup() {
  common_setup
  # A sweep distribution: many small goals, one well below the scaled floor.
  # Written twice — once stamped completion-pass, once default thrust — so the
  # ONLY difference between the two runs is the sprint_shape field.
  read -r -d '' GOALS_AND_STORIES <<'YAML' || true
goals:
  - "Goal 1"
  - "Goal 2"
  - "Goal 3"
  - "Goal 4"
  - "Goal 5"
stories:
  - key: "T-S1"
    points: 1
    goal_index: 1
  - key: "T-S2"
    points: 9
    goal_index: 2
  - key: "T-S3"
    points: 9
    goal_index: 3
  - key: "T-S4"
    points: 9
    goal_index: 4
  - key: "T-S5"
    points: 9
    goal_index: 5
YAML

  STAMPED="$TEST_TMP/stamped.yaml"
  DEFAULT="$TEST_TMP/default.yaml"
  {
    printf 'sprint_id: "t"\ntotal_points: 37\nstatus: review\nsprint_shape: completion-pass\n'
    printf '%s\n' "$GOALS_AND_STORIES"
  } > "$STAMPED"
  {
    printf 'sprint_id: "t"\ntotal_points: 37\nstatus: review\n'
    printf '%s\n' "$GOALS_AND_STORIES"
  } > "$DEFAULT"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Floor SKIPPED under completion-pass — the below-floor goal yields no HIGH.
# ---------------------------------------------------------------------------
@test "completion-pass: below-floor goal does NOT produce a HIGH velocity finding" {
  run bash "$EVAL_SCRIPT" --sprint-status "$STAMPED" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  high_count=$(printf '%s\n' "$output" | grep -c '"severity":"High"' || true)
  [ "$high_count" -eq 0 ]
}

@test "completion-pass: rubric-applicability advisory fires exactly once" {
  run bash "$EVAL_SCRIPT" --sprint-status "$STAMPED" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  advisory_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-006"' || true)
  [ "$advisory_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Control — the SAME distribution under default thrust still fires the floor.
# Confirms the skip is gated on the stamp, not a global suppression.
# ---------------------------------------------------------------------------
@test "default thrust: identical below-floor distribution DOES fire a HIGH finding" {
  run bash "$EVAL_SCRIPT" --sprint-status "$DEFAULT" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  high_count=$(printf '%s\n' "$output" | grep -c '"severity":"High"' || true)
  [ "$high_count" -ge 1 ]
}

@test "default thrust: no rubric-applicability advisory is emitted" {
  run bash "$EVAL_SCRIPT" --sprint-status "$DEFAULT" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  advisory_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-006"' || true)
  [ "$advisory_count" -eq 0 ]
}
