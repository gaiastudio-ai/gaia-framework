#!/usr/bin/env bats
# sprint-plan-phase-rendering.bats — prose pins for the sprint plan's
# phase-grouped rendering contract.
#
# The phase helper emits a partition; the sprint plan RENDERS it. The render
# half has no generator script — it is agent-executed prose in the
# gaia-sprint-plan SKILL — so the contract can only be pinned by asserting the
# instructions survive in that file. This follows existing practice in the
# suite, where the same SKILL is pinned by grepping for the instruction text
# (see the capacity-points retirement suite).
#
# Three clauses are pinned, each independently:
#
#   (a) HEADING       — phases render in ascending order under an explicit
#                       `Phase {n}` heading per group;
#   (b) NEVER-FLATTEN — a single phase-1 group is still rendered under its
#                       heading rather than collapsed to a flat list;
#   (c) INTRA-PHASE   — the selection order (priority ordering) is preserved
#                       within each phase.
#
# Why they are pinned separately: all three currently live in one paragraph, so
# a single broad grep would pass while any one clause was quietly dropped. Each
# test targets the phrase that carries its own clause, and each is verified to
# go red when that phrase is removed.
#
# These are documentation pins, not behavioural tests, and they are deliberately
# modest about what they prove: they assert the planner is still INSTRUCTED to
# group by phase, not that any particular rendered plan did so.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan" && pwd)/SKILL.md"
  export SKILL
}
teardown() { common_teardown; }

@test "the sprint-plan SKILL exists and is readable (AC3)" {
  [ -f "$SKILL" ]
  [ -r "$SKILL" ]
}

@test "the sprint plan is instructed to group stories by derived execution phase (AC3)" {
  # The grouping instruction itself: without it the rendered plan is an
  # undifferentiated list and the partition the helper computed is discarded.
  run grep -F 'Group the selected stories by the execution phase derived in Step 3' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "the sprint plan renders each phase under an explicit heading in ascending order (AC3)" {
  # Clause (a). Both halves are asserted — ascending ORDER and the explicit
  # HEADING — because a plan that grouped correctly but emitted phases
  # descending, or grouped without headings, would satisfy neither the
  # consumer contract nor the acceptance criterion.
  run grep -F 'render the phases in ascending order under an explicit `Phase {n}` heading' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "a single phase-1 group is still rendered under its heading, never flattened (AC3)" {
  # Clause (b). The degenerate case: when every selected story is independent
  # the derivation yields one phase, and the tempting simplification is to drop
  # the heading and print a flat list. That silently changes the plan's shape
  # exactly when a reader is most likely to assume phases are absent rather
  # than uniform.
  run grep -F 'a single `Phase 1` group is still rendered as a group, never flattened away' "$SKILL"
  [ "$status" -eq 0 ]
  # The rule is stated as covering EVERY phase, not just the multi-phase case.
  run grep -F 'Every phase present in the derivation gets a heading' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "the selection order is preserved within each phase (AC3)" {
  # Clause (c). The helper emits intra-phase members in first-appearance order,
  # which is the planner's own selection (priority) order; the render must not
  # re-sort them. Pinned separately from the heading clause so that dropping
  # the ordering guarantee cannot hide behind the grouping instruction.
  run grep -F 'preserve the Step 3 selection order (priority ordering) within each phase' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "stories sharing a phase are documented as having no ordering constraint (AC3)" {
  # The reason the grouping is worth rendering at all: same-phase stories may
  # run concurrently. If this sentence goes, the heading becomes decorative and
  # a reader has no basis for parallelising anything.
  run grep -F 'Stories inside one phase carry no ordering constraint between them' "$SKILL"
  [ "$status" -eq 0 ]
}
