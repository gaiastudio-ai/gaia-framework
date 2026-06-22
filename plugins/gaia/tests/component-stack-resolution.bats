#!/usr/bin/env bats
# component-stack-resolution.bats — pins the narrowing + fan-out behaviour of
# the component stacks carved out of the broad gaia-core suite (the
# scripts-lib / skills / brain / review-common decomposition).
#
# Each component stack owns a source subtree and runs only that component's
# manifest tests on a change confined to it; because those subtrees are
# depended on by the core suite, gaia-core is pulled in via its cross_refs (so
# narrowing never produces a false-green — the component runs its fast subset
# AND the full suite still runs). A core-only or agents-only change does NOT
# run the component stacks. The staging->main promotion runs the full set.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CFG="$REPO_ROOT/.gaia/ci-config.yaml"
  DETECT="$REPO_ROOT/plugins/gaia/scripts/detect-affected.sh"
  CROSS="$REPO_ROOT/plugins/gaia/scripts/cross-refs-walk.sh"
}

@test "the CI slice declares the component stacks (AC3)" {
  for s in gaia-core gaia-scripts-lib gaia-skills gaia-brain gaia-review-common gaia-scripts-sprint; do
    grep -q "name: $s" "$CFG"
  done
}

# --- single-component changes resolve to their narrow stack ----------------

@test "a scripts/lib change resolves to gaia-scripts-lib (AC1)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/lib/resolve-config.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-scripts-lib"]' ]
}

@test "a scripts/brain change resolves to gaia-brain (AC1)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/brain/gaia-brain-reindex.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-brain"]' ]
}

@test "a scripts/review-common change resolves to gaia-review-common (AC1)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/review-common/foo.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-review-common"]' ]
}

@test "a skills change resolves to gaia-skills, not the broad core stack (AC1)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/skills/gaia-meeting/SKILL.md
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-skills"]' ]
}

@test "a sprint state-machine script change resolves to gaia-scripts-sprint (AC1)" {
  # sprint-state.sh is in the sprint family; its exact-literal path wins over
  # gaia-core's broad scripts/** glob (the resolver's exact-literal pass).
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/sprint-state.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-scripts-sprint"]' ]
}

@test "another sprint-family script (transition-story-status) resolves to gaia-scripts-sprint (AC1)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/transition-story-status.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-scripts-sprint"]' ]
}

@test "a NON-sprint top-level scripts change stays in gaia-core (AC1)" {
  # gen-ci-config.sh is a top-level foundation script but not in the sprint
  # family, so it falls to gaia-core's scripts/** glob.
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/gen-ci-config.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-core"]' ]
}

@test "an agents change stays in gaia-core (AC1)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/agents/pm.md
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-core"]' ]
}

# --- cross_refs fan-out: a component change pulls in core (no false-green) ---

@test "a scripts/lib change fans out to gaia-core via cross_refs (AC4)" {
  run "$CROSS" --config "$CFG" --stacks '["gaia-scripts-lib"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gaia-scripts-lib"'* ]]
  [[ "$output" == *'"gaia-core"'* ]]
}

@test "a skills change fans out to gaia-core via cross_refs (AC4)" {
  run "$CROSS" --config "$CFG" --stacks '["gaia-skills"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gaia-skills"'* ]]
  [[ "$output" == *'"gaia-core"'* ]]
}

@test "a sprint-family change fans out to gaia-core via cross_refs (AC4)" {
  # gaia-core declares cross_refs to gaia-scripts-sprint, so a sprint change
  # runs its fast subset AND the full core suite — no false-green.
  run "$CROSS" --config "$CFG" --stacks '["gaia-scripts-sprint"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gaia-scripts-sprint"'* ]]
  [[ "$output" == *'"gaia-core"'* ]]
}

@test "a core-only change does NOT fan out to the component stacks (AC4)" {
  run "$CROSS" --config "$CFG" --stacks '["gaia-core"]'
  [ "$status" -eq 0 ]
  [[ "$output" != *'"gaia-scripts-lib"'* ]]
  [[ "$output" != *'"gaia-skills"'* ]]
  [[ "$output" != *'"gaia-brain"'* ]]
  [[ "$output" != *'"gaia-review-common"'* ]]
  [[ "$output" != *'"gaia-scripts-sprint"'* ]]
}

# --- promotion still runs the full suite ------------------------------------

@test "a promotion-push escalates to the full-suite wildcard (AC5)" {
  run "$DETECT" --config "$CFG" --event promotion-push --files plugins/gaia/scripts/lib/x.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["*"]' ]
}
