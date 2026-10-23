#!/usr/bin/env bats
# sgr-velocity-003 floor scaling — verify the per-goal floor formula
# never produces a total exceeding 100% for any number of goals, and
# that the rubric JSON formula matches the evaluator.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
EVAL_SCRIPT="$PLUGIN_DIR/scripts/rubric-evaluate.sh"
RUBRIC="$PLUGIN_DIR/rubrics/base/sprint-review.json"

setup() { common_setup; }
teardown() { common_teardown; }

# Helper: generate a sprint-status fixture with N goals where every goal
# has equal share (balanced). Total points = 10*N.
# Args: $1=n_goals, $2=outfile, $3=story_status (default "done").
_gen_balanced_fixture() {
  local n_goals="$1" outfile="$2"
  local story_status="${3:-done}"
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
      printf '    status: "%s"\n' "$story_status"
      printf '    points: 10\n'
      printf '    goal_index: %d\n' "$g"
    done
  } > "$outfile"
}

# Helper: generate a 4-goal fixture with specific point splits.
# Args: $1=outfile, $2=p1, $3=p2, $4=p3, $5=p4, $6=status for goal-4 story
#       (default "done"). All other stories are "done".
_gen_4goal_fixture() {
  local outfile="$1" p1="$2" p2="$3" p3="$4" p4="$5"
  local g4_status="${6:-done}"
  local total=$(( p1 + p2 + p3 + p4 ))
  {
    printf 'sprint_id: "test-4goal-uneven"\n'
    printf 'total_points: %d\n' "$total"
    printf 'status: review\n'
    printf 'goals:\n'
    printf '  - "Goal 1"\n'
    printf '  - "Goal 2"\n'
    printf '  - "Goal 3"\n'
    printf '  - "Goal 4"\n'
    printf 'stories:\n'
    printf '  - key: "E900-S1"\n'
    printf '    title: "Story 1"\n'
    printf '    status: "done"\n'
    printf '    points: %d\n' "$p1"
    printf '    goal_index: 1\n'
    printf '  - key: "E900-S2"\n'
    printf '    title: "Story 2"\n'
    printf '    status: "done"\n'
    printf '    points: %d\n' "$p2"
    printf '    goal_index: 2\n'
    printf '  - key: "E900-S3"\n'
    printf '    title: "Story 3"\n'
    printf '    status: "done"\n'
    printf '    points: %d\n' "$p3"
    printf '    goal_index: 3\n'
    printf '  - key: "E900-S4"\n'
    printf '    title: "Story 4"\n'
    printf '    status: "%s"\n' "$g4_status"
    printf '    points: %d\n' "$p4"
    printf '    goal_index: 4\n'
  } > "$outfile"
}

# ---------------------------------------------------------------------------
# AC1 — floor sum never exceeds 100% for N=1..12 (evaluator)
# ---------------------------------------------------------------------------
@test "floor sum never exceeds 100 pct for N=1 through 12 (evaluator)" {
  for n_goals in 1 2 3 4 5 6 7 8 9 10 11 12; do
    local fixture="$TEST_TMP/fixture-${n_goals}.yaml"
    _gen_balanced_fixture "$n_goals" "$fixture"
    run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC" --emit-floor
    [ "$status" -eq 0 ]
    local floor_pct
    floor_pct=$(printf '%s\n' "$output" | /usr/bin/grep '"meta":"floor"' | python3 -c "import sys,json; print(json.load(sys.stdin)['floor_pct'])")
    local total
    total=$(python3 -c "print(round($n_goals * $floor_pct, 6))")
    # Allow a tiny rounding tolerance (floor_pct is rounded to 4 decimals)
    local ok
    ok=$(python3 -c "print('yes' if $n_goals * $floor_pct <= 1.005 else 'no')")
    if [ "$ok" != "yes" ]; then
      echo "FAIL: N=$n_goals floor_pct=$floor_pct total=$total exceeds 100%" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# AC1 — evaluate the JSON floor_pct_expression for N=1..12, assert sum <= 1.0,
# assert equality with evaluator floor, and verify every examples entry.
# ---------------------------------------------------------------------------
@test "JSON floor_pct_expression yields sum <= 1.0 for N=1..12 and matches evaluator" {
  local expr
  expr=$(jq -r '.severity_rules[] | select(.id=="sgr-velocity-003") | .formula.floor_pct_expression' "$RUBRIC")
  [ -n "$expr" ]
  [ "$expr" != "null" ]

  for n_goals in 1 2 3 4 5 6 7 8 9 10 11 12; do
    # Evaluate the JSON expression directly (substitute N)
    local json_floor
    json_floor=$(python3 -c "
N = $n_goals
result = $expr
print(round(result, 4))
")
    # Assert sum of N * floor <= 1.0 (allow rounding tolerance for 4-dp floor)
    local sum_ok
    sum_ok=$(python3 -c "print('yes' if $n_goals * $json_floor <= 1.005 else 'no')")
    if [ "$sum_ok" != "yes" ]; then
      echo "FAIL: JSON expression for N=$n_goals yields floor=$json_floor, sum=$(python3 -c "print($n_goals * $json_floor)") > 1.0" >&2
      return 1
    fi

    # Compare with evaluator floor
    local fixture="$TEST_TMP/json-check-${n_goals}.yaml"
    _gen_balanced_fixture "$n_goals" "$fixture"
    run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC" --emit-floor
    [ "$status" -eq 0 ]
    local eval_floor
    eval_floor=$(printf '%s\n' "$output" | /usr/bin/grep '"meta":"floor"' | python3 -c "import sys,json; print(json.load(sys.stdin)['floor_pct'])")
    if [ "$json_floor" != "$eval_floor" ]; then
      echo "FAIL: N=$n_goals JSON floor=$json_floor != evaluator floor=$eval_floor" >&2
      return 1
    fi
  done
}

@test "JSON examples entries match the floor_pct_expression" {
  local expr
  expr=$(jq -r '.severity_rules[] | select(.id=="sgr-velocity-003") | .formula.floor_pct_expression' "$RUBRIC")

  # Iterate over every key in examples
  local keys
  keys=$(jq -r '.severity_rules[] | select(.id=="sgr-velocity-003") | .formula.examples | keys[]' "$RUBRIC")
  [ -n "$keys" ]
  local key
  for key in $keys; do
    local n_val
    n_val="${key#N=}"
    local expected
    expected=$(jq -r --arg k "$key" '.severity_rules[] | select(.id=="sgr-velocity-003") | .formula.examples[$k]' "$RUBRIC")
    local computed
    computed=$(python3 -c "
N = $n_val
result = $expr
print(round(result, 4))
")
    # Compare numerically (JSON may have trailing zeros like 0.30 vs 0.3)
    local match
    match=$(python3 -c "print('yes' if abs(float('$computed') - float('$expected')) < 1e-6 else 'no')")
    if [ "$match" != "yes" ]; then
      echo "FAIL: examples[$key] = $expected but expression gives $computed" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# AC1 — the formula expression in the rubric carries the per-goal cap
# ---------------------------------------------------------------------------
@test "sgr-velocity-003 formula in rubric contains the 1.0/N cap" {
  local expr
  expr=$(jq -r '.severity_rules[] | select(.id=="sgr-velocity-003") | .formula.floor_pct_expression' "$RUBRIC")
  [ -n "$expr" ]
  [ "$expr" != "null" ]
  # Must contain min(1.0 / N, ...) or equivalent
  [[ "$expr" == *"1.0 / N"* ]]
}

# ---------------------------------------------------------------------------
# AC1 — N<4 floor is pinned at 0.30
# ---------------------------------------------------------------------------
@test "floor is 0.30 for N=1 through 3" {
  for n_goals in 1 2 3; do
    local fixture="$TEST_TMP/pin-${n_goals}.yaml"
    _gen_balanced_fixture "$n_goals" "$fixture"
    run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC" --emit-floor
    [ "$status" -eq 0 ]
    local floor_val
    floor_val=$(printf '%s\n' "$output" | /usr/bin/grep '"meta":"floor"' | python3 -c "import sys,json; print(json.load(sys.stdin)['floor_pct'])")
    if [ "$floor_val" != "0.3" ]; then
      echo "FAIL: N=$n_goals floor=$floor_val, expected 0.3" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# AC2 — N=4 fully delivered passes (balanced split, no findings)
# ---------------------------------------------------------------------------
@test "4 goals fully delivered (balanced) emits no sgr-velocity-003 findings" {
  local fixture="$TEST_TMP/fixture-4.yaml"
  _gen_balanced_fixture 4 "$fixture"
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  local finding_count
  finding_count=$(printf '%s\n' "$output" | /usr/bin/grep -c '"rule_id":"sgr-velocity-003"' || true)
  [ "$finding_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — fully delivered uneven splits all pass (no findings)
# ---------------------------------------------------------------------------
@test "4 goals fully delivered at 13/13/12/12 emits no findings" {
  local fixture="$TEST_TMP/uneven-13-13-12-12.yaml"
  _gen_4goal_fixture "$fixture" 13 13 12 12
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  local fc
  fc=$(printf '%s\n' "$output" | /usr/bin/grep -c '"rule_id":"sgr-velocity-003"' || true)
  [ "$fc" -eq 0 ]
}

@test "4 goals fully delivered at 26/25/25/24 emits no findings" {
  local fixture="$TEST_TMP/uneven-26-25-25-24.yaml"
  _gen_4goal_fixture "$fixture" 26 25 25 24
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  local fc
  fc=$(printf '%s\n' "$output" | /usr/bin/grep -c '"rule_id":"sgr-velocity-003"' || true)
  [ "$fc" -eq 0 ]
}

@test "4 goals fully delivered at 6/5/5/4 emits no findings" {
  local fixture="$TEST_TMP/uneven-6-5-5-4.yaml"
  _gen_4goal_fixture "$fixture" 6 5 5 4
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  local fc
  fc=$(printf '%s\n' "$output" | /usr/bin/grep -c '"rule_id":"sgr-velocity-003"' || true)
  [ "$fc" -eq 0 ]
}

@test "4 goals fully delivered at extreme 40/4/3/3 emits no findings" {
  local fixture="$TEST_TMP/uneven-40-4-3-3.yaml"
  _gen_4goal_fixture "$fixture" 40 4 3 3
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  local fc
  fc=$(printf '%s\n' "$output" | /usr/bin/grep -c '"rule_id":"sgr-velocity-003"' || true)
  [ "$fc" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — same splits with one story not done in the small goal still fire
# ---------------------------------------------------------------------------
@test "13/13/12/12 with goal-4 story in-progress fires for goal 4" {
  local fixture="$TEST_TMP/notdone-13-13-12-12.yaml"
  _gen_4goal_fixture "$fixture" 13 13 12 12 "in-progress"
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"goal_index":4'* ]]
}

@test "6/5/5/4 with goal-4 story blocked fires for goal 4" {
  local fixture="$TEST_TMP/notdone-6-5-5-4.yaml"
  _gen_4goal_fixture "$fixture" 6 5 5 4 "blocked"
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"goal_index":4'* ]]
}

@test "40/4/3/3 with goal-4 story in-progress fires for goal 4" {
  local fixture="$TEST_TMP/notdone-40-4-3-3.yaml"
  _gen_4goal_fixture "$fixture" 40 4 3 3 "in-progress"
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"goal_index":4'* ]]
}

# ---------------------------------------------------------------------------
# AC2 — goal with zero stories behaves as before (not fully delivered)
# ---------------------------------------------------------------------------
@test "goal with zero stories is not exempt from floor check" {
  # 4 goals, but goal 4 has no stories at all (0 points, 0% share).
  local fixture="$TEST_TMP/zero-stories.yaml"
  cat > "$fixture" <<'YAML'
sprint_id: "test-zero-stories"
total_points: 30
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
    points: 12
    goal_index: 1
  - key: "E900-S2"
    title: "Story 2"
    status: "done"
    points: 10
    goal_index: 2
  - key: "E900-S3"
    title: "Story 3"
    status: "done"
    points: 8
    goal_index: 3
YAML
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  # Goal 4 has 0 stories / 0% share — not exempt, should fire
  [[ "$output" == *'"goal_index":4'* ]]
}

# ---------------------------------------------------------------------------
# AC2 — mixed-status goal: one done + one in-progress story must fire
# ---------------------------------------------------------------------------
@test "below-floor goal with one done and one in-progress story fires" {
  local fixture="$TEST_TMP/mixed-status.yaml"
  cat > "$fixture" <<'YAML'
sprint_id: "test-mixed-status"
total_points: 50
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
    points: 20
    goal_index: 1
  - key: "E900-S2"
    title: "Story 2"
    status: "done"
    points: 15
    goal_index: 2
  - key: "E900-S3"
    title: "Story 3"
    status: "done"
    points: 12
    goal_index: 3
  - key: "E900-S4a"
    title: "Story 4a"
    status: "done"
    points: 2
    goal_index: 4
  - key: "E900-S4b"
    title: "Story 4b"
    status: "in-progress"
    points: 1
    goal_index: 4
YAML
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  # Goal 3 (24%, all done) is at floor — must NOT appear in findings.
  local g3_count
  g3_count=$(printf '%s\n' "$output" | grep -c '"goal_index":3' || true)
  [ "$g3_count" -eq 0 ]
  # Goal 4 (6%, one done + one in-progress) is below floor and not
  # fully delivered — must fire with a severity.
  local g4_line
  g4_line=$(printf '%s\n' "$output" | /usr/bin/grep '"goal_index":4')
  [ -n "$g4_line" ]
  [[ "$g4_line" == *'"severity":"High"'* ]]
}

@test "mixed-status goal fires regardless of story order (done last)" {
  # Same as above but the done story comes AFTER the in-progress one.
  # Kills a "last story decides" mutant in the all() check.
  local fixture="$TEST_TMP/mixed-reversed.yaml"
  cat > "$fixture" <<'YAML'
sprint_id: "test-mixed-reversed"
total_points: 50
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
    points: 20
    goal_index: 1
  - key: "E900-S2"
    title: "Story 2"
    status: "done"
    points: 15
    goal_index: 2
  - key: "E900-S3"
    title: "Story 3"
    status: "done"
    points: 12
    goal_index: 3
  - key: "E900-S4b"
    title: "Story 4b (in-progress listed first)"
    status: "in-progress"
    points: 1
    goal_index: 4
  - key: "E900-S4a"
    title: "Story 4a (done listed last)"
    status: "done"
    points: 2
    goal_index: 4
YAML
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"goal_index":4'* ]]
}

# ---------------------------------------------------------------------------
# AC3 — balanced N=4..12 with in-progress stories also emit 0 findings
# (proves the >= floor comparison, not just the fully-delivered skip)
# ---------------------------------------------------------------------------
@test "parametric N=4 through 12 in-progress balanced all pass (at floor)" {
  for n_goals in 4 5 6 7 8 9 10 11 12; do
    local fixture="$TEST_TMP/inprog-${n_goals}.yaml"
    _gen_balanced_fixture "$n_goals" "$fixture" "in-progress"
    run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
    [ "$status" -eq 0 ]
    local finding_count
    finding_count=$(printf '%s\n' "$output" | /usr/bin/grep -c '"rule_id":"sgr-velocity-003"' || true)
    if [ "$finding_count" -ne 0 ]; then
      echo "FAIL: N=$n_goals in-progress balanced but got $finding_count findings" >&2
      echo "Output: $output" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# AC3 — parametric N=4..12: every fully-delivered balanced goal count passes
# ---------------------------------------------------------------------------
@test "parametric N=4 through 12 fully delivered (balanced) all pass" {
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
# AC3 — N=4 one goal under floor fires for that goal
# ---------------------------------------------------------------------------
@test "4 goals with one under floor fires sgr-velocity-003 for that goal" {
  local fixture="$TEST_TMP/fixture-4-under.yaml"
  # 4 goals, total 20 points. Goal 4 gets only 1 point (5% share)
  # and its story is in-progress, so the floor check fires.
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
    status: "in-progress"
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
# AC3 — boundary: goal exactly 5pp below floor is MEDIUM (not HIGH)
# ---------------------------------------------------------------------------
@test "goal exactly 5pp below floor is graded MEDIUM not HIGH" {
  # 5-goal, 20 total points, floor=0.20. Goal 4 at 15% = exactly 5pp below.
  # Goals 4 and 5 have in-progress stories so they are NOT exempt.
  local fixture="$TEST_TMP/boundary-5pp.yaml"
  cat > "$fixture" <<'YAML'
sprint_id: "test-5pp-boundary"
total_points: 20
status: review
goals:
  - "Goal 1"
  - "Goal 2"
  - "Goal 3"
  - "Goal 4"
  - "Goal 5"
stories:
  - key: "E900-S1"
    title: "Story 1"
    status: "done"
    points: 6
    goal_index: 1
  - key: "E900-S2"
    title: "Story 2"
    status: "done"
    points: 5
    goal_index: 2
  - key: "E900-S3"
    title: "Story 3"
    status: "done"
    points: 4
    goal_index: 3
  - key: "E900-S4"
    title: "Story 4"
    status: "in-progress"
    points: 3
    goal_index: 4
  - key: "E900-S5"
    title: "Story 5"
    status: "in-progress"
    points: 2
    goal_index: 5
YAML
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  # Goal 4 at 15% is exactly 5pp below 20% floor: delta=0.05 → MEDIUM
  local g4_line
  g4_line=$(printf '%s\n' "$output" | /usr/bin/grep '"goal_index":4')
  [[ "$g4_line" == *'"severity":"Medium"'* ]]
  # Goal 5 at 10% is 10pp below: delta=0.10 → HIGH
  local g5_line
  g5_line=$(printf '%s\n' "$output" | /usr/bin/grep '"goal_index":5')
  [[ "$g5_line" == *'"severity":"High"'* ]]
}

# ---------------------------------------------------------------------------
# AC3 — large N under-floor case (N=10)
# ---------------------------------------------------------------------------
@test "N=10 goal under floor fires sgr-velocity-003" {
  local fixture="$TEST_TMP/fixture-10-under.yaml"
  # 10 goals, 100 total points. Goal 10 gets only 2 points (2% share).
  # Floor for N=10 = min(0.10, max(0.10, 0.12)) = 0.10.
  {
    printf 'sprint_id: "test-10-goal-under"\n'
    printf 'total_points: 100\n'
    printf 'status: review\n'
    printf 'goals:\n'
    local g
    for g in $(seq 1 10); do
      printf '  - "Goal %d"\n' "$g"
    done
    printf 'stories:\n'
    for g in $(seq 1 9); do
      printf '  - key: "E900-S%d"\n' "$g"
      printf '    title: "Story %d"\n' "$g"
      printf '    status: "done"\n'
      # Goals 1-9 share 98 points evenly (about 10.9% each → above 10% floor)
      if [ "$g" -le 8 ]; then
        printf '    points: 11\n'
      else
        printf '    points: 10\n'
      fi
      printf '    goal_index: %d\n' "$g"
    done
    # Goal 10 gets only 2 points (2% share, below 10% floor).
    # Story is in-progress so the goal is NOT exempt.
    printf '  - key: "E900-S10"\n'
    printf '    title: "Story 10"\n'
    printf '    status: "in-progress"\n'
    printf '    points: 2\n'
    printf '    goal_index: 10\n'
  } > "$fixture"
  run bash "$EVAL_SCRIPT" --sprint-status "$fixture" --rubric "$RUBRIC"
  [ "$status" -eq 0 ]
  # Goal 10 at 2% is far below 10% floor → should fire HIGH
  [[ "$output" == *'"goal_index":10'* ]]
  local g10_line
  g10_line=$(printf '%s\n' "$output" | /usr/bin/grep '"goal_index":10')
  [[ "$g10_line" == *'"severity":"High"'* ]]
}

# ---------------------------------------------------------------------------
# AC4 — no internal IDs in changed files
# ---------------------------------------------------------------------------
@test "no internal traceability IDs in changed plugin files" {
  local rc=0
  for f in "$EVAL_SCRIPT" "$RUBRIC"; do
    if /usr/bin/grep -En 'FR-[0-9]{2,}|NFR-[0-9]{2,}|ADR-[0-9]{2,}' "$f"; then
      echo "FAIL: leaked requirement/ADR ID in $f" >&2
      rc=1
    fi
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
  local fixture="$TEST_TMP/verify-write.yaml"
  _gen_balanced_fixture 2 "$fixture"
  [ -f "$fixture" ]
  [[ "$TEST_TMP" != "$PLUGIN_DIR"* ]]
}
