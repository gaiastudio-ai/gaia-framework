#!/usr/bin/env bats
# checkpoint-write-boundary.bats — write-boundary now allows _memory/meeting-sessions/*.yaml
# (E76-S7, FR-MTG-31 amended)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/write-boundary.sh"
}

@test "write boundary allows _memory/meeting-sessions/*.yaml" {
  run "$HELPER" "_memory/meeting-sessions/2026-05-08-test.yaml"
  [ "$status" -eq 0 ]
}

@test "write boundary allows nested subpaths under _memory/meeting-sessions/ (defensive)" {
  run "$HELPER" "_memory/meeting-sessions/2026-05/test.yaml"
  [ "$status" -eq 0 ]
}

@test "write boundary still REJECTS arbitrary _memory/ files outside meeting-sessions" {
  run "$HELPER" "_memory/sprint-status.yaml"
  [ "$status" -eq 2 ]
}

@test "write boundary still passes the pre-existing allow-list entries" {
  run "$HELPER" "docs/creative-artifacts/meeting-2026-05-08-test.md"
  [ "$status" -eq 0 ]
  run "$HELPER" "docs/planning-artifacts/action-items.yaml"
  [ "$status" -eq 0 ]
  run "$HELPER" "_memory/architect-sidecar/decisions/2026-05-08-test.md"
  [ "$status" -eq 0 ]
}

@test "write boundary still REJECTS paths outside the allow-list" {
  run "$HELPER" "docs/planning-artifacts/prd.md"
  [ "$status" -eq 2 ]
}
