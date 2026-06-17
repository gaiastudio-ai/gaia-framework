#!/usr/bin/env bats
# e103-s4-sprint-close-advisory-checklist.bats
# Story: E103-S4 — /gaia-sprint-close advisory checklist of skipped artifact-producing skills.
# Origin: AF-2026-05-24-3. Traces to: FR-538, ADR-120, TC-LOE-4.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLOSE_SH="$PLUGIN/skills/gaia-sprint-close/scripts/close.sh"
}

teardown() { common_teardown; }

@test "close.sh preserves retro-existence hard-gate (regression)" {
  [ -f "$CLOSE_SH" ]
  grep -qF "retro doc not found" "$CLOSE_SH"
}

@test "close.sh references the advisory-checklist marker section" {
  [ -f "$CLOSE_SH" ]
  grep -qF "Lifecycle Skill Checklist (advisory)" "$CLOSE_SH"
}

@test "close.sh sources the lifecycle-overrides helper" {
  [ -f "$CLOSE_SH" ]
  grep -qF "lifecycle-overrides.sh" "$CLOSE_SH"
}

@test "close.sh enumerates canonical lifecycle skills in the checklist" {
  [ -f "$CLOSE_SH" ]
  grep -qF "gaia-trace" "$CLOSE_SH"
  grep -qF "gaia-readiness-check" "$CLOSE_SH"
  grep -qF "gaia-threat-model" "$CLOSE_SH"
}

@test "close.sh emits the all-present summary line marker" {
  [ -f "$CLOSE_SH" ]
  grep -qF "All lifecycle skills produced their canonical artifacts" "$CLOSE_SH"
}
