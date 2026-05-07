#!/usr/bin/env bats
# write-boundary.bats — gaia-meeting state-free write boundary (E76-S1)
#
# AC8 / FR-MTG-31: writes confined to docs/creative-artifacts/, _memory/action-items/,
#                  _memory/{agent}-sidecar/decisions/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/write-boundary.sh"
}

@test "Pre-flight: write-boundary.sh exists and is executable" {
  [ -x "$HELPER" ]
}

# Reject-cases must not pass via exit 127 (command not found); guard with -x check
_helper_required() {
  [ -x "$HELPER" ]
}

@test "AC8: docs/creative-artifacts/ is allowed" {
  _helper_required
  run "$HELPER" "docs/creative-artifacts/meeting-2026-05-07-foo.md"
  [ "$status" -eq 0 ]
}

@test "AC8: _memory/action-items/ is allowed" {
  run "$HELPER" "_memory/action-items/2026-05-07-foo.md"
  [ "$status" -eq 0 ]
}

@test "AC8: _memory/{agent}-sidecar/decisions/ is allowed" {
  run "$HELPER" "_memory/architect-sidecar/decisions/AD-1.md"
  [ "$status" -eq 0 ]
}

@test "AC8: docs/planning-artifacts/sprint-status.yaml is REJECTED" {
  _helper_required
  run "$HELPER" "docs/planning-artifacts/sprint-status.yaml"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC8: docs/implementation-artifacts/ (story files) is REJECTED" {
  _helper_required
  run "$HELPER" "docs/implementation-artifacts/E1-S1-foo.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC8: docs/planning-artifacts/prd/ is REJECTED" {
  _helper_required
  run "$HELPER" "docs/planning-artifacts/prd/01.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC8: docs/planning-artifacts/architecture/ is REJECTED" {
  _helper_required
  run "$HELPER" "docs/planning-artifacts/architecture/01.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC8: docs/test-artifacts/ is REJECTED" {
  _helper_required
  run "$HELPER" "docs/test-artifacts/strategy/test-plan.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC8: _memory/checkpoints/ is REJECTED (state-free invariant)" {
  _helper_required
  run "$HELPER" "_memory/checkpoints/foo.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC8: traceability under docs/test-artifacts/ is REJECTED" {
  _helper_required
  run "$HELPER" "docs/test-artifacts/strategy/traceability-matrix.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
