#!/usr/bin/env bats
# gaia-sprint-wiring-boundary-writes.bats — TC-SGR-44 boundary-write anti-pattern static check.
#
# Story: E93-S5. Traces to AC4, NFR-071, T-SGR-7, ADR-095.
#
# Verifies that no skill under {gaia-sprint-plan, gaia-correct-course,
# gaia-sprint-close} directly mutates sprint-status.yaml via `yq -i` or
# `sed -i` — all writes MUST route through sprint-state.sh subcommands.

setup() {
  export GAIA_SNAPSHOT_HOOK_DISABLE=1
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

@test ".3: gaia-sprint-close delegates all state writes to sprint-state.sh close writer" {
  # close.sh delegates all state-file writes to the sprint-state.sh close
  # writer. Verify it references sprint-state.sh for the close path.
  grep -qE "sprint-state\.sh.*close|SPRINT_STATE_SH.*close" "$SPRINT_CLOSE_DIR/scripts/close.sh" \
    || grep -qE "sprint-state\.sh[[:space:]]+transition" "$SPRINT_CLOSE_DIR/scripts/close.sh" \
    || grep -qE "close.*writer|delegat.*sprint-state" "$SPRINT_CLOSE_DIR/SKILL.md"
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
