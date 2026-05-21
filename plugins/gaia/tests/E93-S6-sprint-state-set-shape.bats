#!/usr/bin/env bats
# E93-S6 — sprint-state.sh set-shape subcommand coverage.
#
# Public functions covered: cmd_set_shape (NFR-052 coverage gate).
#
# AC1 — set-shape subcommand validates enum {thrust, completion-pass} and
# uses the ADR-095 boundary-write pattern.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SPRINT_STATE="$PLUGIN_DIR/scripts/sprint-state.sh"

setup() {
  common_setup
  # Build a minimal sprint-status.yaml the script will resolve to.
  PROJECT_ROOT="$TEST_TMP/proj"
  mkdir -p "$PROJECT_ROOT/.gaia/state"
  cat > "$PROJECT_ROOT/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "test-sprint"
duration: "2 weeks"
velocity_capacity: 25
team_size: 1
total_points: 10
capacity_utilization: "40%"
status: active
goals:
  - "Goal 1"
stories:
  - key: "T-S1"
    title: "Story 1"
    status: "ready-for-dev"
    points: 10
YAML
  export PROJECT_PATH="$PROJECT_ROOT"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — set-shape accepts valid enum values and writes the field.
# ---------------------------------------------------------------------------
@test "AC1: set-shape --shape completion-pass writes sprint_shape field" {
  run bash "$SPRINT_STATE" set-shape --sprint test-sprint --shape completion-pass
  [ "$status" -eq 0 ]
  run grep -E '^sprint_shape:[[:space:]]*completion-pass' "$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
  [ "$status" -eq 0 ]
}

@test "AC1: set-shape --shape thrust writes sprint_shape field" {
  run bash "$SPRINT_STATE" set-shape --sprint test-sprint --shape thrust
  [ "$status" -eq 0 ]
  run grep -E '^sprint_shape:[[:space:]]*thrust' "$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
  [ "$status" -eq 0 ]
}

@test "AC1: set-shape --shape bogus rejects with canonical stderr and exits non-zero" {
  run bash -c "bash '$SPRINT_STATE' set-shape --sprint test-sprint --shape bogus 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint_shape must be one of"* ]]
}

@test "AC1: set-shape preserves existing YAML structure (comments and ordering)" {
  # Add a comment line before re-running
  cat > "$PROJECT_ROOT/.gaia/state/sprint-status.yaml" <<'YAML'
# Sprint-50 — completion-pass sweep
sprint_id: "test-sprint"
duration: "2 weeks"
velocity_capacity: 25
team_size: 1
total_points: 10
capacity_utilization: "40%"
status: active
goals:
  - "Goal 1"
stories:
  - key: "T-S1"
    title: "Story 1"
    status: "ready-for-dev"
    points: 10
YAML
  run bash "$SPRINT_STATE" set-shape --sprint test-sprint --shape completion-pass
  [ "$status" -eq 0 ]
  # Comment must still be present
  run grep -F "# Sprint-50 — completion-pass sweep" "$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
  [ "$status" -eq 0 ]
}

@test "AC1: set-shape idempotent — running twice with same value yields same final content" {
  bash "$SPRINT_STATE" set-shape --sprint test-sprint --shape completion-pass
  cp "$PROJECT_ROOT/.gaia/state/sprint-status.yaml" "$TEST_TMP/first.yaml"
  bash "$SPRINT_STATE" set-shape --sprint test-sprint --shape completion-pass
  run diff "$TEST_TMP/first.yaml" "$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
  [ "$status" -eq 0 ]
}

@test "AC1: set-shape updates the field on re-run with a new value" {
  bash "$SPRINT_STATE" set-shape --sprint test-sprint --shape thrust
  run bash "$SPRINT_STATE" set-shape --sprint test-sprint --shape completion-pass
  [ "$status" -eq 0 ]
  run grep -E '^sprint_shape:[[:space:]]*completion-pass' "$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
  [ "$status" -eq 0 ]
  # Ensure no duplicate sprint_shape lines were written
  count=$(grep -cE '^sprint_shape:' "$PROJECT_ROOT/.gaia/state/sprint-status.yaml" || true)
  [ "$count" -eq 1 ]
}
