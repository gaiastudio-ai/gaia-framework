#!/usr/bin/env bats
# default-mode.bats — gaia-meeting default mode resolver (E76-S1)
#
# AC4 / FR-MTG-17: default mode = decide (no --mode flag)
# FR-MTG-16: single-mode-only invariant — reject mode stacking

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/resolve-mode.sh"
}

@test "Pre-flight: resolve-mode.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC4: no --mode flag resolves to decide" {
  run "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "decide" ]
}

@test "AC4: --mode decide explicit pass-through" {
  run "$HELPER" --mode decide
  [ "$status" -eq 0 ]
  [ "$output" = "decide" ]
}

@test "AC4: --mode brainstorm returns brainstorm" {
  run "$HELPER" --mode brainstorm
  [ "$status" -eq 0 ]
  [ "$output" = "brainstorm" ]
}

@test "FR-MTG-16: mode stacking rejected (--mode decide --mode brainstorm)" {
  [ -x "$HELPER" ]
  run "$HELPER" --mode decide --mode brainstorm
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
  [[ "$output" == *"single"* ]] || [[ "$output" == *"stack"* ]] || [[ "$output" == *"one"* ]]
}

@test "FR-MTG-16: unknown mode rejected" {
  [ -x "$HELPER" ]
  run "$HELPER" --mode notamode
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC4: decide mode is documented as injecting no default invitees" {
  # Substrate check — SKILL.md must declare the bias
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/SKILL.md"
  [ -f "$SKILL_FILE" ]
  grep -qiE "decision.record|decision-record" "$SKILL_FILE"
  grep -qE "user.specified|user-specified" "$SKILL_FILE"
}
