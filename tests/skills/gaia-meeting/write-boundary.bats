#!/usr/bin/env bats
# write-boundary.bats — gaia-meeting state-free write boundary
#
# The meeting workflow confines every write to the creative-artifacts meeting
# notes, the action-items registry, the per-agent sidecar decisions trees and
# the custom-skills seam. Everything else — sprint state, story files, the
# requirements document, architecture, the test plan, traceability — is
# refused.
#
# Roots are resolved through the same path helper the shipped scripts use
# rather than restated as literals here, so a future tree move is picked up
# automatically instead of leaving these assertions pinned to the old shape.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/write-boundary.sh"
  load helpers/runtime-paths
  gaia_load_runtime_paths "$REPO_ROOT" || {
    skip "runtime path helper unavailable; cannot resolve the tree the way production does"
  }
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
  run "$HELPER" "$GAIA_REL_ARTIFACTS/creative-artifacts/meeting-2026-05-07-foo.md"
  [ "$status" -eq 0 ]
}

@test "the action-items registry is allowed" {
  _helper_required
  run "$HELPER" "$GAIA_REL_STATE/action-items.yaml"
  [ "$status" -eq 0 ]
}

@test "an agent sidecar decisions path is allowed" {
  run "$HELPER" "$GAIA_REL_MEMORY/architect-sidecar/decisions/decision-1.md"
  [ "$status" -eq 0 ]
}

@test "a memory-rooted action-items path is rejected" {
  _helper_required
  run "$HELPER" "$GAIA_REL_MEMORY/action-items/2026-05-07-foo.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the sprint-status file is rejected" {
  _helper_required
  run "$HELPER" "$GAIA_REL_STATE/sprint-status.yaml"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "story files under the implementation-artifacts root are rejected" {
  _helper_required
  run "$HELPER" "$GAIA_REL_ARTIFACTS/implementation-artifacts/some-story.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the requirements-document directory is rejected" {
  _helper_required
  run "$HELPER" "$GAIA_REL_ARTIFACTS/planning-artifacts/prd/01.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the architecture directory is rejected" {
  _helper_required
  run "$HELPER" "$GAIA_REL_ARTIFACTS/planning-artifacts/architecture/01.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the test-artifacts root is rejected" {
  _helper_required
  run "$HELPER" "$GAIA_REL_ARTIFACTS/test-artifacts/strategy/test-plan.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the checkpoints directory is rejected, keeping the meeting state-free" {
  _helper_required
  run "$HELPER" "$GAIA_REL_MEMORY/checkpoints/foo.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "the traceability matrix under the test-artifacts root is rejected" {
  _helper_required
  run "$HELPER" "$GAIA_REL_ARTIFACTS/test-artifacts/strategy/traceability-matrix.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
