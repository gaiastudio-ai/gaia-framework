#!/usr/bin/env bats
# checkpoint-write-boundary.bats — the write boundary admits the meeting
# session-state files so interactive checkpointing can persist, while still
# refusing everything else under the memory root.
#
# Roots are resolved through the same path helper the shipped scripts use
# rather than restated as literals here.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/write-boundary.sh"
  load helpers/runtime-paths
  gaia_load_runtime_paths "$REPO_ROOT" || {
    skip "runtime path helper unavailable; cannot resolve the tree the way production does"
  }
}

@test "the write boundary allows a meeting session-state file" {
  run "$HELPER" "$GAIA_REL_MEMORY/meeting-sessions/2026-05-08-test.yaml"
  [ "$status" -eq 0 ]
}

@test "the write boundary allows a nested session-state subpath" {
  run "$HELPER" "$GAIA_REL_MEMORY/meeting-sessions/2026-05/test.yaml"
  [ "$status" -eq 0 ]
}

@test "the write boundary still rejects memory-root files outside meeting sessions" {
  run "$HELPER" "$GAIA_REL_MEMORY/sprint-status.yaml"
  [ "$status" -eq 2 ]
}

@test "the write boundary still passes the other allow-list entries" {
  run "$HELPER" "$GAIA_REL_ARTIFACTS/creative-artifacts/meeting-2026-05-08-test.md"
  [ "$status" -eq 0 ]
  run "$HELPER" "$GAIA_REL_STATE/action-items.yaml"
  [ "$status" -eq 0 ]
  run "$HELPER" "$GAIA_REL_MEMORY/architect-sidecar/decisions/2026-05-08-test.md"
  [ "$status" -eq 0 ]
}

@test "the write boundary still rejects paths outside the allow-list" {
  run "$HELPER" "$GAIA_REL_ARTIFACTS/planning-artifacts/prd.md"
  [ "$status" -eq 2 ]
}
