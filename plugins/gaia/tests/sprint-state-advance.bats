#!/usr/bin/env bats
# sprint-state-advance.bats — advance subcommand tests
#
# Covers the close-to-next-sprint scaffold:
#   - advance round-trip: closed predecessor -> new planned sprint
#   - advance refuses non-closed predecessor (planned/active/review)
#   - advance requires --sprint-id
#   - advance delegates to the init re-seed path (shared logic)
#   - SKILL.md documents the advance-to-next-sprint path

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-state.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  ART="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  STATE_DIR="$TEST_TMP/.gaia/state"
  YAML="$STATE_DIR/sprint-status.yaml"
  export SPRINT_STATUS_YAML="$YAML"
  mkdir -p "$ART" "$STATE_DIR"
}
teardown() { common_teardown; }

# Seed a closed sprint yaml.
seed_closed_yaml() {
  local sprint_id="$1"
  cat > "$YAML" <<EOF
sprint_id: "$sprint_id"
status: closed
closed_at: "2026-06-25T12:00:00Z"
total_points: 50
goals: []
stories: []
EOF
}

# Seed a non-closed sprint yaml.
seed_yaml_with_status() {
  local sprint_id="$1" sprint_status="$2"
  cat > "$YAML" <<EOF
sprint_id: "$sprint_id"
status: $sprint_status
total_points: 0
goals: []
stories: []
EOF
}

# ============================================================
# advance subcommand round-trip (AC1, AC3)
# ============================================================

@test "advance after close seeds next sprint as planned without manual yaml edit (AC1)" {
  seed_closed_yaml "sprint-70"
  run "$SCRIPT" advance --sprint-id sprint-71
  [ "$status" -eq 0 ]
  # The new sprint is seeded with status: planned
  grep -q '^sprint_id: "sprint-71"' "$YAML"
  grep -q '^status: planned' "$YAML"
  grep -q '^total_points: 0' "$YAML"
}

@test "advance forwards optional date flags to the init path (AC3)" {
  seed_closed_yaml "sprint-70"
  run "$SCRIPT" advance --sprint-id sprint-71 --start-date 2026-06-26 --end-date 2026-07-10
  [ "$status" -eq 0 ]
  grep -q '^sprint_id: "sprint-71"' "$YAML"
  grep -q '^status: planned' "$YAML"
  grep -q '^start_date: "2026-06-26"' "$YAML"
  grep -q '^end_date: "2026-07-10"' "$YAML"
}

# ============================================================
# advance refuses non-closed predecessor (AC1 negative)
# ============================================================

@test "advance refuses when predecessor is planned (AC1)" {
  seed_yaml_with_status "sprint-70" "planned"
  run "$SCRIPT" advance --sprint-id sprint-71
  [ "$status" -ne 0 ]
  [[ "$output" == *"advance:"* ]]
  [[ "$output" == *"close it first"* ]] || [[ "$output" == *"/gaia-sprint-close"* ]]
  # Yaml unchanged — still the old sprint
  grep -q '^sprint_id: "sprint-70"' "$YAML"
}

@test "advance refuses when predecessor is active (AC1)" {
  seed_yaml_with_status "sprint-70" "active"
  run "$SCRIPT" advance --sprint-id sprint-71
  [ "$status" -ne 0 ]
  [[ "$output" == *"advance:"* ]]
  [[ "$output" == *"close it first"* ]] || [[ "$output" == *"/gaia-sprint-close"* ]]
  grep -q '^sprint_id: "sprint-70"' "$YAML"
}

@test "advance refuses when predecessor is review (AC1)" {
  seed_yaml_with_status "sprint-70" "review"
  run "$SCRIPT" advance --sprint-id sprint-71
  [ "$status" -ne 0 ]
  [[ "$output" == *"advance:"* ]]
  [[ "$output" == *"close it first"* ]] || [[ "$output" == *"/gaia-sprint-close"* ]]
  grep -q '^sprint_id: "sprint-70"' "$YAML"
}

# ============================================================
# advance requires --sprint-id
# ============================================================

@test "advance requires --sprint-id flag (AC3)" {
  seed_closed_yaml "sprint-70"
  run "$SCRIPT" advance
  [ "$status" -ne 0 ]
  [[ "$output" == *"--sprint-id"* ]]
}

# ============================================================
# subcmd-aware messages: advance emits "advance:" not "init:"
# ============================================================

@test "advance over closed predecessor emits advance: prefix in re-seeding notice" {
  seed_closed_yaml "sprint-70"
  run "$SCRIPT" advance --sprint-id sprint-71
  [ "$status" -eq 0 ]
  # The re-seeding stderr notice must say "advance:", not "init:"
  [[ "$output" == *"advance: re-seeding"* ]] || [[ "$output" == *"advance: seeded"* ]]
  # Must NOT contain "init:" in any message
  ! [[ "$output" == *"init:"* ]]
}

@test "advance sprint-plan stub records generated_by advance" {
  seed_closed_yaml "sprint-70"
  export IMPLEMENTATION_ARTIFACTS="$ART"
  run "$SCRIPT" advance --sprint-id sprint-71
  [ "$status" -eq 0 ]
  local plan_stub="$ART/sprint-plan/sprint-71-plan.md"
  [ -f "$plan_stub" ]
  grep -q 'generated_by: sprint-state.sh advance' "$plan_stub"
  grep -q 'sprint-state.sh advance' "$plan_stub"
}

# ============================================================
# advance appears in usage/help (AC2 partial — discoverability)
# ============================================================

@test "advance subcommand appears in sprint-state.sh --help (AC2)" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"advance"* ]]
}

# ============================================================
# SKILL.md doc-coverage (AC2)
# ============================================================

@test "sprint-close SKILL.md documents how to advance to the next sprint (AC2)" {
  local skill_md
  skill_md="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"
  [ -f "$skill_md" ]
  # Must contain a section or paragraph about advancing to the next sprint
  grep -qi 'advance.*next sprint\|next sprint.*advance\|advancing to the next sprint\|scaffold.*next sprint' "$skill_md"
}

@test "sprint-close SKILL.md references sprint-state.sh advance (AC2)" {
  local skill_md
  skill_md="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"
  [ -f "$skill_md" ]
  grep -q 'sprint-state.sh advance' "$skill_md"
}
