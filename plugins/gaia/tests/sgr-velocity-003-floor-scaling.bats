#!/usr/bin/env bats
# sgr-velocity-003 floor scaling — verify the per-goal floor formula
# never produces a total exceeding 100% for any number of goals.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
EVAL_SCRIPT="$PLUGIN_DIR/scripts/rubric-evaluate.sh"
RUBRIC="$PLUGIN_DIR/rubrics/base/sprint-review.json"

setup() { common_setup; }
teardown() { common_teardown; }

# Helper: generate a sprint-status fixture with N goals where every goal
# has equal share (fully delivered, balanced). Total points = 10*N.
# Writes to $1.
_gen_balanced_fixture() {
  local n_goals="$1" outfile="$2"
  local total_pts=$(( 10 * n_goals ))
  {
    printf 'sprint_id: "test-%d-goal"\n' "$n_goals"
    printf 'total_points: %d\n' "$total_pts"
    printf 'status: review\n'
    printf 'goals:\n'
    local g
    for g in $(seq 1 "$n_goals"); do
      printf '  - "Goal %d"\n' "$g"
    done
    printf 'stories:\n'
    for g in $(seq 1 "$n_goals"); do
      printf '  - key: "E900-S%d"\n' "$g"
      printf '    title: "Story for goal %d"\n' "$g"
      printf '    status: "done"\n'
      printf '    points: 10\n'
      printf '    goal_index: %d\n' "$g"
    done
  } > "$outfile"
}

# ---------------------------------------------------------------------------
# AC1 — floor sum never exceeds 100% for N=1..12
# ---------------------------------------------------------------------------
@test "floor sum never exceeds 100 pct for N=1 through 12" {
  for n_goals in 1 2 3 4 5 6 7 8 9 10 11 12; do
    local fixture="$TEST_TMP/fixture-${n_goals}.yaml"
    _gen_balanced_fixture "$n_goals" "$fixture"
    run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC" --emit-floor
    [ "$status" -eq 0 ]
    # Extract floor_pct from the meta record
    local floor_pct
    floor_pct=$(printf '%s\n' "$output" | /usr/bin/grep '"meta":"floor"' | python3 -c "import sys,json; print(json.load(sys.stdin)['floor_pct'])")
    # Compute total = N * floor_pct, must be <= 1.0
    local total
    total=$(python3 -c "print(round($n_goals * $floor_pct, 6))")
    local ok
    # Allow a tiny rounding tolerance (floor_pct is rounded to 4 decimals)
    ok=$(python3 -c "print('yes' if $n_goals * $floor_pct <= 1.005 else 'no')")
    if [ "$ok" != "yes" ]; then
      echo "FAIL: N=$n_goals floor_pct=$floor_pct total=$total exceeds 100%" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# AC2 — N=4 fully delivered passes (no sgr-velocity-003 findings)
# ---------------------------------------------------------------------------
@test "4 goals fully delivered emits no sgr-velocity-003 findings" {
  local fixture="$TEST_TMP/fixture-4.yaml"
  _gen_balanced_fixture 4 "$fixture"
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  local finding_count
  finding_count=$(printf '%s\n' "$output" | /usr/bin/grep -c '"rule_id":"sgr-velocity-003"' || true)
  [ "$finding_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — parametric N=4..12: every fully-delivered goal count passes
# ---------------------------------------------------------------------------
@test "parametric N=4 through 12 fully delivered all pass" {
  for n_goals in 4 5 6 7 8 9 10 11 12; do
    local fixture="$TEST_TMP/fixture-${n_goals}.yaml"
    _gen_balanced_fixture "$n_goals" "$fixture"
    run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
    [ "$status" -eq 0 ]
    local finding_count
    finding_count=$(printf '%s\n' "$output" | /usr/bin/grep -c '"rule_id":"sgr-velocity-003"' || true)
    if [ "$finding_count" -ne 0 ]; then
      echo "FAIL: N=$n_goals fully delivered but got $finding_count sgr-velocity-003 findings" >&2
      echo "Output: $output" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# AC3 — N=4 one goal under floor still fails for that goal
# ---------------------------------------------------------------------------
@test "4 goals with one under floor fires sgr-velocity-003 for that goal" {
  local fixture="$TEST_TMP/fixture-4-under.yaml"
  # 4 goals, total 20 points. Goal 4 gets only 1 point (5% share).
  cat > "$fixture" <<'YAML'
sprint_id: "test-4-goal-under"
total_points: 20
status: review
goals:
  - "Goal 1"
  - "Goal 2"
  - "Goal 3"
  - "Goal 4"
stories:
  - key: "E900-S1"
    title: "Story 1"
    status: "done"
    points: 7
    goal_index: 1
  - key: "E900-S2"
    title: "Story 2"
    status: "done"
    points: 7
    goal_index: 2
  - key: "E900-S3"
    title: "Story 3"
    status: "done"
    points: 5
    goal_index: 3
  - key: "E900-S4"
    title: "Story 4"
    status: "done"
    points: 1
    goal_index: 4
YAML
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  # Goal 4 at 5% is below the floor — should fire
  local finding_count
  finding_count=$(printf '%s\n' "$output" | /usr/bin/grep -c '"rule_id":"sgr-velocity-003"' || true)
  [ "$finding_count" -ge 1 ]
  # Specifically goal 4
  [[ "$output" == *'"goal_index":4'* ]]
}

# ---------------------------------------------------------------------------
# AC1 — the formula in sprint-review.json carries a total-sum cap
# ---------------------------------------------------------------------------
@test "sgr-velocity-003 formula in rubric caps total to 100 pct" {
  # Extract the formula expression and verify it contains a 1.0/N cap
  local expr
  expr=$(jq -r '.severity_rules[] | select(.id=="sgr-velocity-003") | .formula.floor_pct_expression' "$RUBRIC")
  [ -n "$expr" ]
  [ "$expr" != "null" ]
  # The expression must contain a per-goal cap (1.0/N or equivalent)
  # that prevents N*floor > 1.0
  [[ "$expr" == *"1.0"* ]] || [[ "$expr" == *"1 /"* ]] || [[ "$expr" == *"/ N"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — no internal IDs in changed files
# ---------------------------------------------------------------------------
@test "no internal traceability IDs in changed plugin files" {
  # Check the evaluator script and rubric for leaked IDs.
  # Synthetic fixture keys (E900-S*) are excluded.
  local rc=0
  for f in "$EVAL_SCRIPT" "$RUBRIC"; do
    if /usr/bin/grep -En 'FR-[0-9]{2,}|NFR-[0-9]{2,}|ADR-[0-9]{2,}' "$f"; then
      echo "FAIL: leaked requirement/ADR ID in $f" >&2
      rc=1
    fi
    # Real story keys — E<digits>-S<digits> but NOT E900 range (test fixtures)
    if /usr/bin/grep -En 'E[0-9]+-S[0-9]+' "$f" | /usr/bin/grep -v 'E900-S'; then
      echo "FAIL: leaked story key in $f" >&2
      rc=1
    fi
  done
  [ "$rc" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5 — tests never write into real plugin tree
# ---------------------------------------------------------------------------
@test "all fixtures use temp dirs not real plugin tree" {
  # Verify our helper writes to TEST_TMP
  local fixture="$TEST_TMP/verify-write.yaml"
  _gen_balanced_fixture 2 "$fixture"
  [ -f "$fixture" ]
  # TEST_TMP must be under BATS temp, not under PLUGIN_DIR
  [[ "$TEST_TMP" != "$PLUGIN_DIR"* ]]
}
