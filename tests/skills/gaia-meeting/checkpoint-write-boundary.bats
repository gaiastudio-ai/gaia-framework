#!/usr/bin/env bats
# checkpoint-write-boundary.bats — write-boundary now allows _memory/meeting-sessions/*.yaml
# (E76-S7, FR-MTG-31 amended)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/write-boundary.sh"
}

@test "FR-MTG-31 amended: _memory/meeting-sessions/*.yaml is allowed" {
  run "$HELPER" "_memory/meeting-sessions/2026-05-08-test.yaml"
  [ "$status" -eq 0 ]
}

@test "FR-MTG-31 amended: _memory/meeting-sessions/ allows nested subpaths (defensive)" {
  run "$HELPER" "_memory/meeting-sessions/2026-05/test.yaml"
  [ "$status" -eq 0 ]
}

@test "FR-MTG-31 amended: arbitrary _memory/ files outside meeting-sessions are still REJECTED" {
  run "$HELPER" "_memory/sprint-status.yaml"
  [ "$status" -eq 2 ]
}

@test "FR-MTG-31 amended: existing allow-list entries still pass" {
  run "$HELPER" "docs/creative-artifacts/meeting-2026-05-08-test.md"
  [ "$status" -eq 0 ]
  run "$HELPER" "docs/planning-artifacts/action-items.yaml"
  [ "$status" -eq 0 ]
  run "$HELPER" "_memory/architect-sidecar/decisions/2026-05-08-test.md"
  [ "$status" -eq 0 ]
}

@test "FR-MTG-31 amended: outside-allow-list paths are still REJECTED" {
  run "$HELPER" "docs/planning-artifacts/prd.md"
  [ "$status" -eq 2 ]
}
