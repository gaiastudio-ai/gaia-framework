#!/usr/bin/env bats
# e39-s7-triage-gate.bats — TC-STCL-9/10: mandatory triage gate in sprint-close.
# Asserts the per-sprint triage proof-of-run sentinel write/check behavior and
# the sprint-close prerequisite documentation.

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SENTINEL="$PLUGIN/skills/gaia-triage-findings/scripts/triage-sentinel.sh"
  SPRINT_CLOSE_SKILL="$PLUGIN/skills/gaia-sprint-close/SKILL.md"
  TRIAGE_SKILL="$PLUGIN/skills/gaia-triage-findings/SKILL.md"
  CK="$BATS_TEST_TMPDIR/checkpoints"
  mkdir -p "$CK"
}

# TC-STCL-9 — check FAILS (non-zero) when the triage sentinel is absent.
@test "TC-STCL-9: triage-sentinel check fails when triage has not run" {
  run "$SENTINEL" check --sprint-id sprint-77 --checkpoints-dir "$CK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"triage not run"* ]]
}

# TC-STCL-10 — write then check PASSES (exit 0) when triage has run.
@test "TC-STCL-10: triage-sentinel check passes after triage writes the sentinel" {
  run "$SENTINEL" write --sprint-id sprint-77 --checkpoints-dir "$CK"
  [ "$status" -eq 0 ]
  [ -f "$CK/triage-findings-sprint-77-completed.json" ]
  run "$SENTINEL" check --sprint-id sprint-77 --checkpoints-dir "$CK"
  [ "$status" -eq 0 ]
}

# Path-safety: a sprint-id with a path separator is rejected (no traversal).
@test "TC-STCL-10b: triage-sentinel rejects an unsafe sprint-id" {
  run "$SENTINEL" write --sprint-id "../evil" --checkpoints-dir "$CK"
  [ "$status" -ne 0 ]
}

# AC1/AC4 — sprint-close documents the mandatory triage prerequisite with the
# canonical remedy message and the review→triage→retro→close sequence.
@test "TC-STCL-9b: sprint-close SKILL.md documents the mandatory triage gate" {
  grep -qF "triage-sentinel.sh" "$SPRINT_CLOSE_SKILL"
  grep -qF "run /gaia-triage-findings {sprint_id} first" "$SPRINT_CLOSE_SKILL"
  grep -qF "review → triage → retro → close" "$SPRINT_CLOSE_SKILL"
}

# AC4 — triage SKILL.md notes its mandatory sprint-close role.
@test "TC-STCL-9c: triage SKILL.md documents its sprint-close prerequisite role" {
  grep -qiF "mandatory sprint-close prerequisite" "$TRIAGE_SKILL"
  grep -qF "review → triage → retro → close" "$TRIAGE_SKILL"
}
