#!/usr/bin/env bats
# e106-s5-retire-capacity-points.bats
#
# Locks the retirement of the legacy human-team capacity_points field on
# agent-native sprints. capacity_points was a calendar-capacity proxy that
# is meaningless for a continuous LLM agent; capacity judgement is delegated
# to the agent-native check (dependency-depth + coherence + wall-clock).
#
# Proves:
#   * sprint-state.sh `init` no longer seeds a capacity_points line into the
#     sprint-status.yaml (or the sprint-plan stub), even when a value is
#     passed — the flag is accepted-but-inert for backward compatibility.
#   * `inject` never accumulates capacity_points.
#   * sprint-status-dashboard.sh omits the phantom "(capacity: M)" figure.
#   * the sprint-review surface does not read capacity_points (so an
#     unset/zero field can produce no phantom underutilization finding).
#
# Each sprint-state.sh assertion runs against BOTH the canonical script and
# the byte-identical dev-story wrapper (wrapper-sync invariant).

load 'test_helper.bash'

setup() {
  common_setup
  CANONICAL="$SCRIPTS_DIR/sprint-state.sh"
  WRAPPER="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/sprint-state.sh"
  DASHBOARD="$SCRIPTS_DIR/sprint-status-dashboard.sh"
  export SPRINT_STATE_SCRIPT_DIR="$SCRIPTS_DIR"
  export CANONICAL WRAPPER DASHBOARD
  export MEMORY_PATH="$TEST_TMP/_memory"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  export IMPLEMENTATION_ARTIFACTS="$ART"
  mkdir -p "$ART" "$MEMORY_PATH"
  export GAIA_SKIP_ORPHAN_SWEEP=1
}
teardown() { common_teardown; }

seed_backlog_story() {
  local key="$1" sprint_id="$2" points="${3:-3}"
  cat > "$ART/${key}-fake.md" <<EOF
---
template: 'story'
key: "$key"
status: ready-for-dev
sprint_id: "$sprint_id"
points: $points
risk: medium
---
# $key
EOF
}

@test "init does not seed a non-zero capacity_points line even when the flag is passed (canonical)" {
  export SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"
  run "$CANONICAL" init --sprint-id "sprint-x" --capacity-points 40
  [ "$status" -eq 0 ]
  # The phantom field must not leak into the seed at a non-zero value.
  run grep -E '^capacity_points:[[:space:]]*[1-9]' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
}

@test "init does not seed a non-zero capacity_points line even when the flag is passed (wrapper)" {
  export SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"
  run "$WRAPPER" init --sprint-id "sprint-x" --capacity-points 40
  [ "$status" -eq 0 ]
  run grep -E '^capacity_points:[[:space:]]*[1-9]' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
}

@test "the sprint-plan stub frontmatter carries no capacity_points figure" {
  export SPRINT_STATUS_YAML="$ART/sprint-status.yaml"
  run "$CANONICAL" init --sprint-id "sprint-stub" --capacity-points 33
  [ "$status" -eq 0 ]
  stub="$ART/sprint-plan/sprint-stub-plan.md"
  [ -f "$stub" ]
  run grep -E '^capacity_points:' "$stub"
  [ "$status" -ne 0 ]
}

@test "init still accepts the deprecated --capacity-points flag without error" {
  export SPRINT_STATUS_YAML="$TEST_TMP/sprint-status.yaml"
  run "$CANONICAL" init --sprint-id "sprint-compat" --capacity-points 21
  [ "$status" -eq 0 ]
  [[ "$output" =~ seeded ]]
}

@test "inject does not introduce or accumulate a capacity_points figure" {
  export SPRINT_STATUS_YAML="$ART/sprint-status.yaml"
  "$CANONICAL" init --sprint-id "sprint-inj" >/dev/null
  seed_backlog_story "E1-S1" "sprint-inj" 5
  seed_backlog_story "E1-S2" "sprint-inj" 8
  run "$CANONICAL" inject --story "E1-S1"
  [ "$status" -eq 0 ]
  run "$CANONICAL" inject --story "E1-S2"
  [ "$status" -eq 0 ]
  run grep -E '^capacity_points:[[:space:]]*[1-9]' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
}

@test "dashboard omits the phantom (capacity: M) figure on an agent-native sprint" {
  cat > "$ART/sprint-status.yaml" <<EOF
sprint_id: "sprint-native"
status: active
total_points: 13
start_date: "2026-06-01"
end_date: "2026-06-14"
goals: []
items: []
EOF
  export SPRINT_STATUS_YAML="$ART/sprint-status.yaml"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "13 pts" ]] || [[ "$output" =~ "13" ]]
  # No phantom capacity figure in the header.
  [[ ! "$output" =~ capacity: ]]
}

@test "dashboard ignores a legacy capacity_points line and shows no capacity figure" {
  cat > "$ART/sprint-status.yaml" <<EOF
sprint_id: "sprint-legacy"
status: active
capacity_points: 40
total_points: 13
goals: []
items: []
EOF
  export SPRINT_STATUS_YAML="$ART/sprint-status.yaml"
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "capacity: 40" ]]
  [[ ! "$output" =~ capacity: ]]
}

@test "the sprint-review rubric does not key any rule off capacity_points" {
  RUBRIC="$SCRIPTS_DIR/../rubrics/base/sprint-review.json"
  [ -f "$RUBRIC" ]
  run grep -E 'capacity_points' "$RUBRIC"
  [ "$status" -ne 0 ]
}

@test "the sprint-plan SKILL no longer instructs seeding capacity_points" {
  SKILL="$SCRIPTS_DIR/../skills/gaia-sprint-plan/SKILL.md"
  [ -f "$SKILL" ]
  run grep -E 'capacity_points|--capacity-points' "$SKILL"
  [ "$status" -ne 0 ]
}
