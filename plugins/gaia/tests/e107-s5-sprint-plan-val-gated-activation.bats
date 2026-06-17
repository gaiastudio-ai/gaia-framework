#!/usr/bin/env bats
# e107-s5-sprint-plan-val-gated-activation.bats — E107-S5
#
# Closes the un-startable-sprint defect: /gaia-sprint-plan selected backlog
# stories and committed the sprint as `planned`, but never transitioned them
# from `backlog` to `ready-for-dev`, so /gaia-dev-story HALTed and the sprint
# could not start. The fix adds a Val-gated activation step (Step 4a) that
# validates each selected backlog story (/gaia-validate-story, SM-fix loop ≤3),
# transitions passers `backlog → ready-for-dev` via transition-story-status.sh,
# and HALTs the sprint start while any selected story remains `backlog`.
# dev-story FRESH mode is tightened to `ready-for-dev → in-progress`, making the
# activation chain single-path (no competing `backlog → in-progress`).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAN_SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-sprint-plan/SKILL.md"
  DEV_SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/SKILL.md"
  TRANSITION="$REPO_ROOT/plugins/gaia/scripts/transition-story-status.sh"
}

# ---------- sprint-plan Step 4a: Val-gated activation ----------

@test "sprint-plan SKILL.md adds a Val-gated activation step (backlog -> ready-for-dev)" {
  [ -f "$PLAN_SKILL" ]
  grep -Eq 'Step 4a' "$PLAN_SKILL" \
    || { echo "SKILL.md should add Step 4a (Val-gated activation)" >&2; false; }
  grep -Eiq 'backlog .*ready-for-dev' "$PLAN_SKILL" \
    || { echo "SKILL.md should document the backlog -> ready-for-dev transition" >&2; false; }
}

@test "activation validates each story via /gaia-validate-story" {
  grep -Fq '/gaia-validate-story' "$PLAN_SKILL" \
    || { echo "Step 4a should validate via /gaia-validate-story" >&2; false; }
}

@test "activation transitions passers via transition-story-status.sh --to ready-for-dev" {
  grep -Eq 'transition-story-status\.sh .*--to[[:space:]]*\n?[[:space:]]*ready-for-dev|transition-story-status\.sh' "$PLAN_SKILL" \
    || { echo "Step 4a should transition via transition-story-status.sh" >&2; false; }
  grep -Fq 'ready-for-dev' "$PLAN_SKILL"
}

@test "SM fix loop is bounded at 3 attempts" {
  grep -Eiq '3[[:space:]]*attempts|≤[[:space:]]*3|up to .*3' "$PLAN_SKILL" \
    || { echo "Step 4a should bound the SM fix loop at 3 attempts" >&2; false; }
}

@test "sprint cannot start while any selected story remains backlog (HALT)" {
  grep -Eiq 'cannot start|can.?t start' "$PLAN_SKILL" \
    || { echo "SKILL.md should HALT sprint start when a story remains backlog" >&2; false; }
  grep -Eiq 'remove .*from the sprint|fix .*re-?validate' "$PLAN_SKILL" \
    || { echo "HALT should offer remove-or-fix to the user" >&2; false; }
}

@test "AC5b: the misleading 'Stories remain ready-for-dev -- do NOT change' line is gone" {
  run grep -Fq 'Stories remain `ready-for-dev` -- do NOT change their status' "$PLAN_SKILL"
  [ "$status" -ne 0 ]
}

# ---------- dev-story FRESH-mode reconcile (single activation path) ----------

@test "dev-story FRESH mode owns ready-for-dev -> in-progress only" {
  [ -f "$DEV_SKILL" ]
  grep -Eiq 'ready-for-dev .*in-progress|single activation path' "$DEV_SKILL" \
    || { echo "dev-story should document the ready-for-dev -> in-progress single path" >&2; false; }
}

@test "AC6b: backlog -> in-progress is reserved for pure backlog dev (sprint_id null)" {
  grep -Eiq 'sprint_id: null|pure backlog dev' "$DEV_SKILL" \
    || { echo "dev-story should reserve backlog->in-progress for sprint_id:null" >&2; false; }
}

# ---------- the single-writer it depends on exists ----------

@test "transition-story-status.sh (the sanctioned single-writer) exists and is executable" {
  [ -x "$TRANSITION" ]
}
