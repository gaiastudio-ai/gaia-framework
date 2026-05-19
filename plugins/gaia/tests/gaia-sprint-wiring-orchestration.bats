#!/usr/bin/env bats
# gaia-sprint-wiring-orchestration.bats — TC-SGR-41..43 prose-grep verification
# of the new sprint-level edges wired into /gaia-sprint-plan + /gaia-correct-course
# + /gaia-sprint-close per E93-S5.
#
# Story: E93-S5. Traces to AC1, AC2, AC3, AC5, AC6.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/../skills"
  SPRINT_PLAN_SKILL="$PLUGIN_DIR/gaia-sprint-plan/SKILL.md"
  CORRECT_COURSE_SKILL="$PLUGIN_DIR/gaia-correct-course/SKILL.md"
  SPRINT_CLOSE_SKILL="$PLUGIN_DIR/gaia-sprint-close/SKILL.md"
}

# ============================================================================
# TC-SGR-41 — /gaia-sprint-plan 3-lane goal router (AC1)
# ============================================================================

@test "TC-SGR-41.1: sprint-plan SKILL.md references the 3-lane router by name (FR-486)" {
  grep -q "3-lane" "$SPRINT_PLAN_SKILL"
}

@test "TC-SGR-41.2: sprint-plan SKILL.md contains literal 'user-direct' lane label" {
  grep -q "user-direct" "$SPRINT_PLAN_SKILL"
}

@test "TC-SGR-41.3: sprint-plan SKILL.md contains literal 'pm-route' lane label" {
  grep -q "pm-route" "$SPRINT_PLAN_SKILL"
}

@test "TC-SGR-41.4: sprint-plan SKILL.md contains literal 'yolo' lane label" {
  grep -q '"yolo"\|`yolo`' "$SPRINT_PLAN_SKILL"
}

@test "TC-SGR-41.5: sprint-plan SKILL.md references 'sprint-state.sh set-goals'" {
  grep -q "set-goals" "$SPRINT_PLAN_SKILL"
}

@test "TC-SGR-41.6: sprint-plan SKILL.md references main-turn Agent dispatch to Val (ADR-093/ADR-104)" {
  grep -qE "main-turn.*Agent.*Val|Agent tool.*Val|Val.*main-turn" "$SPRINT_PLAN_SKILL"
}

@test "TC-SGR-41.7: PM-cannot-self-approve regression — pm-route lane re-prompts USER, not PM" {
  # The SKILL.md MUST contain text indicating the final accept comes from the user, not the PM.
  grep -qiE "user.*final.accept|user.*accept|PM.*cannot.*self.approve|not.*the.*PM" "$SPRINT_PLAN_SKILL"
}

@test "TC-SGR-41.8: sprint-plan SKILL.md references FR-486 or AC1 traceability" {
  grep -qE "FR-486|E93-S5|AC1" "$SPRINT_PLAN_SKILL"
}

# ============================================================================
# TC-SGR-42 — /gaia-correct-course review→correction edge (AC2)
# ============================================================================

@test "TC-SGR-42.1: correct-course SKILL.md references '--from-review' flag or auto-detect" {
  grep -qE "from-review|status:.*review" "$CORRECT_COURSE_SKILL"
}

@test "TC-SGR-42.2: correct-course SKILL.md references action-items.yaml" {
  grep -q "action-items.yaml" "$CORRECT_COURSE_SKILL"
}

@test "TC-SGR-42.3: correct-course SKILL.md references story_injection" {
  grep -q "story_injection\|story-injection" "$CORRECT_COURSE_SKILL"
}

@test "TC-SGR-42.4: correct-course SKILL.md references sprint-state.sh inject" {
  grep -qE "sprint-state\.sh[[:space:]]+inject" "$CORRECT_COURSE_SKILL"
}

@test "TC-SGR-42.5: correct-course SKILL.md references the review→correction→active transition sequence" {
  grep -qE "review.*correction|correction.*active" "$CORRECT_COURSE_SKILL"
}

@test "TC-SGR-42.6: correct-course SKILL.md references FR-487 or AC2 traceability" {
  grep -qE "FR-487|E93-S5|FR-492|AC2" "$CORRECT_COURSE_SKILL"
}

# ============================================================================
# TC-SGR-43 — /gaia-sprint-close review→closed edge with sentinel verification (AC3)
# ============================================================================

@test "TC-SGR-43.1: sprint-close SKILL.md references review-gate.sh status read" {
  grep -qE "review-gate\.sh[[:space:]]+status" "$SPRINT_CLOSE_SKILL"
}

@test "TC-SGR-43.2: sprint-close SKILL.md references the review→closed edge" {
  grep -qE "review.*closed|closed.*review" "$SPRINT_CLOSE_SKILL"
}

@test "TC-SGR-43.3: sprint-close SKILL.md references E83 dispatch checkpoint or sprint-review sentinel" {
  grep -qE "sprint-review-.*val-dispatched|val-envelope-|sprint-review.*sentinel" "$SPRINT_CLOSE_SKILL"
}

@test "TC-SGR-43.4: sprint-close SKILL.md references canonical REFUSE stderr on FAILED verdict" {
  grep -qiE "refuse|HALT" "$SPRINT_CLOSE_SKILL"
}

@test "TC-SGR-43.5: sprint-close SKILL.md references UNVERIFIED-with-bypass detection" {
  grep -qE "UNVERIFIED|review_justification" "$SPRINT_CLOSE_SKILL"
}

@test "TC-SGR-43.6: sprint-close SKILL.md references FR-492 or AC3 traceability" {
  grep -qE "FR-492|E93-S5|AC3" "$SPRINT_CLOSE_SKILL"
}
