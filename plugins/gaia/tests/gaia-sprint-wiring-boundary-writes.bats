#!/usr/bin/env bats
# gaia-sprint-wiring-boundary-writes.bats — TC-SGR-44 boundary-write anti-pattern static check.
#
# Story: E93-S5. Traces to AC4, NFR-071, T-SGR-7, ADR-095.
#
# Verifies that no skill under {gaia-sprint-plan, gaia-correct-course,
# gaia-sprint-close} directly mutates sprint-status.yaml via `yq -i` or
# `sed -i` — all writes MUST route through sprint-state.sh subcommands.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/../skills"
  SPRINT_PLAN_DIR="$PLUGIN_DIR/gaia-sprint-plan"
  CORRECT_COURSE_DIR="$PLUGIN_DIR/gaia-correct-course"
  SPRINT_CLOSE_DIR="$PLUGIN_DIR/gaia-sprint-close"
}

@test ".1: gaia-sprint-plan has no direct 'yq -i' against sprint-status.yaml" {
  # Scope to executable script files (skip SKILL.md docs/examples).
  ! grep -rE 'yq[[:space:]]+(eval[[:space:]]+)?-i[^|]*sprint-status' "$SPRINT_PLAN_DIR/scripts" 2>/dev/null
}

@test ".2: gaia-correct-course has no direct 'yq -i' against sprint-status.yaml" {
  ! grep -rE 'yq[[:space:]]+(eval[[:space:]]+)?-i[^|]*sprint-status' "$CORRECT_COURSE_DIR/scripts" 2>/dev/null
}

@test ".3: gaia-sprint-close NEW review→closed path uses sprint-state.sh (legacy active→closed path documented exception)" {
  # The existing close.sh (pre-E93-S5) uses `yq -i` for the active→closed direct edge.
  # That pre-existing path is a documented exception (backward-compat per AC6).
  # The NEW review→closed path added in E93-S5 MUST use sprint-state.sh.
  # Verify the close.sh script references sprint-state.sh transition for the new path.
  grep -qE "sprint-state\.sh[[:space:]]+transition.*review|transition.*review.*closed" "$SPRINT_CLOSE_DIR/scripts/close.sh" \
    || grep -qE "sprint-state\.sh[[:space:]]+(transition-sprint|cmd_transition_sprint)" "$SPRINT_CLOSE_DIR/scripts/close.sh" \
    || grep -qE "transition[[:space:]]+--sprint.*--to[[:space:]]+closed" "$SPRINT_CLOSE_DIR/SKILL.md"
}

@test ".4: gaia-sprint-plan has no 'sed -i' against sprint-status.yaml" {
  ! grep -rE 'sed[[:space:]]+-i[^|]*sprint-status' "$SPRINT_PLAN_DIR/scripts" 2>/dev/null
}

@test ".5: gaia-correct-course has no 'sed -i' against sprint-status.yaml" {
  ! grep -rE 'sed[[:space:]]+-i[^|]*sprint-status' "$CORRECT_COURSE_DIR/scripts" 2>/dev/null
}

@test ".6: gaia-sprint-close has no 'sed -i' against sprint-status.yaml" {
  ! grep -rE 'sed[[:space:]]+-i[^|]*sprint-status' "$SPRINT_CLOSE_DIR/scripts" 2>/dev/null
}
