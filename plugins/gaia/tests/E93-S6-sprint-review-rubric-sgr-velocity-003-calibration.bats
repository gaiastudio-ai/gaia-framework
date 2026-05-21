#!/usr/bin/env bats
# E93-S6 — sgr-velocity-003 incidental-goal floor calibration for completion-pass shape.
#
# Story: E93-S6 (origin: correct-course, AI-2026-05-21-1)
# ADRs:  ADR-108 (sprint-level state machine), ADR-095 (boundary writes),
#        ADR-079/ADR-088 (layered rubric loading).
#
# AC5  fixture-driven coverage of the scaled-floor formula + sprint_shape modifier
# AC6  sprint-50 regression replay produces PASSED Track A verdict

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
EVAL_SCRIPT="$PLUGIN_DIR/scripts/rubric-evaluate.sh"
RUBRIC="$PLUGIN_DIR/rubrics/base/sprint-review.json"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/sprint-review-sgr-velocity-003"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC5(a) — 7-goal completion-pass sweep yields ZERO HIGH findings + exactly
# one rubric-applicability LOW advisory.
# ---------------------------------------------------------------------------
@test "AC5a: 7-goal completion-pass sweep — zero HIGH sgr-velocity-003 findings" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/7-goal-sweep-completion-pass.yaml" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  # No HIGH sgr-velocity-003 findings — all are LOW under completion-pass.
  high_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-003".*"severity":"High"' || true)
  [ "$high_count" -eq 0 ]
}

@test "AC5a: 7-goal completion-pass sweep — exactly one sgr-velocity-006 advisory" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/7-goal-sweep-completion-pass.yaml" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  advisory_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-006"' || true)
  [ "$advisory_count" -eq 1 ]
}

@test "AC5a: 7-goal completion-pass sweep — advisory names scaled floor and goals-below count" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/7-goal-sweep-completion-pass.yaml" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  # Floor = max(0.10, 0.30 * (4/7)) = 0.171... → "17%" or "17.14%" — assert "17"
  [[ "$output" == *"sprint_shape: completion-pass applied"* ]]
  [[ "$output" == *"17"* ]]
}

# ---------------------------------------------------------------------------
# AC5(b) — 2-goal thrust sprint with 5% incidental goal STILL fires HIGH.
# ---------------------------------------------------------------------------
@test "AC5b: 2-goal thrust default — 5% goal fires HIGH sgr-velocity-003" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/2-goal-thrust-default.yaml" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  high_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-003".*"severity":"High"' || true)
  [ "$high_count" -ge 1 ]
}

@test "AC5b: 2-goal thrust default — no sgr-velocity-006 advisory (no completion-pass)" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/2-goal-thrust-default.yaml" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  advisory_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-006"' || true)
  [ "$advisory_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5(c) — 5-goal default sprint scales floor to 24%; below-floor goals
# surface at MEDIUM intermediate severity (not HIGH).
# ---------------------------------------------------------------------------
@test "AC5c: 5-goal default — scaled floor is 24% (computed from formula)" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/5-goal-default.yaml" --rubric "$RUBRIC" --emit-floor
  [ "$status" -eq 0 ]
  # Floor = 0.30 * (4/5) = 0.24 → assert "24" appears
  [[ "$output" == *"floor_pct"*"24"* ]]
}

@test "AC5c: 5-goal default — goals within 5%% of floor emit MEDIUM (intermediate tier)" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/5-goal-default.yaml" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  # Goal 3 (20%) is within 5% of 24% floor → MEDIUM
  medium_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-003".*"severity":"Medium"' || true)
  [ "$medium_count" -ge 1 ]
}

@test "AC5c: 5-goal default — goals >5%% below floor emit HIGH" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/5-goal-default.yaml" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  # Goal 5 (10%) is >5% below 24% floor → HIGH
  high_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-003".*"severity":"High"' || true)
  [ "$high_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# AC6 — sprint-50 regression replay: zero HIGH findings + one sgr-velocity-006
# + all per-goal verdicts PASSED.
# ---------------------------------------------------------------------------
@test "AC6: sprint-50 replay under completion-pass — zero HIGH sgr-velocity-003 findings" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/sprint-50-replay-completion-pass.yaml" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  high_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-003".*"severity":"High"' || true)
  [ "$high_count" -eq 0 ]
}

@test "AC6: sprint-50 replay under completion-pass — exactly one sgr-velocity-006 advisory" {
  run bash "$EVAL_SCRIPT" --sprint-status "$FIXTURES/sprint-50-replay-completion-pass.yaml" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  advisory_count=$(printf '%s\n' "$output" | grep -c '"rule_id":"sgr-velocity-006"' || true)
  [ "$advisory_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC2 — sgr-velocity-003 in JSON carries the scaled-floor formula description.
# ---------------------------------------------------------------------------
@test "AC2: sgr-velocity-003 rubric pattern describes the scaled-floor formula" {
  run jq -r '.severity_rules[] | select(.id=="sgr-velocity-003") | .pattern' "$RUBRIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"floor_pct"* || "$output" == *"4 / max(4"* || "$output" == *"scaled"* ]]
}

@test "AC2: sgr-velocity-003 rubric carries a formula field with the scaling expression" {
  run jq -r '.severity_rules[] | select(.id=="sgr-velocity-003") | .formula' "$RUBRIC"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}

# ---------------------------------------------------------------------------
# AC3 — sgr-velocity-006 advisory rule exists in the rubric at severity Low.
# ---------------------------------------------------------------------------
@test "AC3: sgr-velocity-006 rule exists in rubric at severity Low" {
  run jq -r '.severity_rules[] | select(.id=="sgr-velocity-006") | .severity' "$RUBRIC"
  [ "$status" -eq 0 ]
  [ "$output" = "Low" ]
}

@test "AC3: sgr-velocity-006 category is rubric-applicability" {
  run jq -r '.severity_rules[] | select(.id=="sgr-velocity-006") | .category' "$RUBRIC"
  [ "$status" -eq 0 ]
  [ "$output" = "rubric-applicability" ]
}

# ---------------------------------------------------------------------------
# AC4 — rubric-loader.sh loads the calibrated rubric with zero schema errors.
# ---------------------------------------------------------------------------
@test "AC4: validate-rubric.sh passes against calibrated sprint-review.json" {
  run bash "$PLUGIN_DIR/scripts/validate-rubric.sh" "$RUBRIC"
  [ "$status" -eq 0 ]
}
