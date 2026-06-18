#!/usr/bin/env bats
# issue-1109-stale-sprint-status-shadow.bats
#
# Issue #1109 (deprecated): the legacy mirror that copied
# .gaia/state/sprint-status.yaml to .gaia/artifacts/implementation-artifacts/
# has been retired.  The canonical home for sprint-status.yaml is
# .gaia/state/ — period.  This test pins the post-deprecation contract:
#
#   (a) sprint-state.sh mutations do NOT write a mirror copy.
#   (b) the resolver resolves ONLY .gaia/state/sprint-status.yaml.
#   (c) a pre-existing stale copy at the legacy path is silently ignored
#       (no WARNING emitted).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SPRINT_STATE="$PLUGIN_ROOT/scripts/sprint-state.sh"
  RESOLVER="$PLUGIN_ROOT/scripts/lib/resolve-artifact-path.sh"
  cd "$TEST_TMP"
  mkdir -p .gaia/state .gaia/artifacts/implementation-artifacts
}

teardown() { common_teardown; }

_seed_canonical() {
  printf 'sprint_id: "sprint-22"\nstatus: %s\nstories: []\n' "${1:-closed}" \
    > .gaia/state/sprint-status.yaml
}
_seed_legacy() {
  printf 'sprint_id: "sprint-22"\nstatus: %s\nstories: []\n' "${1:-active}" \
    > .gaia/artifacts/implementation-artifacts/sprint-status.yaml
}

# ---------------------------------------------------------------------------
# Contract (a): mirror is NOT written after a sprint-state mutation
# ---------------------------------------------------------------------------

@test "issue #1109 (deprecated): init does NOT mirror to implementation-artifacts" {
  run env PROJECT_PATH="$TEST_TMP" bash "$SPRINT_STATE" init --sprint-id sprint-55
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.gaia/state/sprint-status.yaml" ]
  [ ! -f "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-status.yaml" ]
}

@test "issue #1109 (deprecated): reconcile does NOT mirror to implementation-artifacts" {
  _seed_canonical active
  run env PROJECT_PATH="$TEST_TMP" bash "$SPRINT_STATE" reconcile --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-status.yaml" ]
}

# ---------------------------------------------------------------------------
# Contract (b): resolver resolves ONLY .gaia/state/
# ---------------------------------------------------------------------------

@test "issue #1109 (deprecated): resolver ignores a stale legacy copy at implementation-artifacts" {
  _seed_canonical closed
  _seed_legacy active
  run "$RESOLVER" sprint_status --project-root "$TEST_TMP" --existing-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/state/sprint-status.yaml" ]]
  [[ "$output" != *"/implementation-artifacts/sprint-status.yaml" ]]
}

# ---------------------------------------------------------------------------
# Contract (c): NO divergence WARNING — the warning block is removed
# ---------------------------------------------------------------------------

@test "issue #1109 (deprecated): no WARNING when canonical and divergent legacy copy coexist" {
  _seed_canonical closed
  _seed_legacy active
  run env PROJECT_PATH="$TEST_TMP" bash "$SPRINT_STATE" reconcile --dry-run
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF "stale legacy sprint-status.yaml"
  ! echo "$output" | grep -qF "remove it to avoid divergence"
  ! echo "$output" | grep -qF "shadows the canonical"
}

@test "issue #1109 (deprecated): no WARNING when only the canonical copy exists" {
  _seed_canonical closed
  run env PROJECT_PATH="$TEST_TMP" bash "$SPRINT_STATE" reconcile --dry-run
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF "stale legacy sprint-status.yaml"
}
