#!/usr/bin/env bats
# write-boundary.bats — gaia-meeting state-free write boundary (E76-S1 + E76-S3)
#
# AC10 (E76-S3) / FR-MTG-31 / ADR-086: writes confined to
#   docs/creative-artifacts/meeting-*.md
#   docs/planning-artifacts/action-items.yaml
#   _memory/{agent}-sidecar/decisions/*.md

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

@test "a meeting note under the creative-artifacts root is allowed" {
  _helper_required
  run "$HELPER" "docs/creative-artifacts/meeting-2026-05-07-foo.md"
  [ "$status" -eq 0 ]
}

@test "the action-items file under the planning-artifacts root is allowed" {
  _helper_required
  run "$HELPER" "docs/planning-artifacts/action-items.yaml"
  [ "$status" -eq 0 ]
}

@test "an agent sidecar decisions path is allowed" {
  run "$HELPER" "_memory/architect-sidecar/decisions/AD-1.md"
  [ "$status" -eq 0 ]
}

@test "the retired memory-rooted action-items path is rejected" {
  _helper_required
  run "$HELPER" "_memory/action-items/2026-05-07-foo.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the sprint-status file is rejected" {
  _helper_required
  run "$HELPER" "docs/planning-artifacts/sprint-status.yaml"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "story files under the implementation-artifacts root are rejected" {
  _helper_required
  run "$HELPER" "docs/implementation-artifacts/E1-S1-foo.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the requirements-document directory is rejected" {
  _helper_required
  run "$HELPER" "docs/planning-artifacts/prd/01.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the architecture directory is rejected" {
  _helper_required
  run "$HELPER" "docs/planning-artifacts/architecture/01.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the test-artifacts root is rejected" {
  _helper_required
  run "$HELPER" "docs/test-artifacts/strategy/test-plan.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the checkpoints directory is rejected, keeping the meeting state-free" {
  _helper_required
  run "$HELPER" "_memory/checkpoints/foo.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the traceability matrix under the test-artifacts root is rejected" {
  _helper_required
  run "$HELPER" "docs/test-artifacts/strategy/traceability-matrix.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
