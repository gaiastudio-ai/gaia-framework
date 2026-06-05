#!/usr/bin/env bats
# issue-1109-stale-sprint-status-shadow.bats
#
# Issue #1109: after the ADR-111 move of sprint-status.yaml to .gaia/state/,
# a legacy …/implementation-artifacts/sprint-status.yaml left on disk could
# silently diverge from (and, on transient .gaia/state/ absence, shadow) the
# canonical copy. The resolver now (a) still lets .gaia/state/ win, and (b)
# emits a loud WARNING when a divergent legacy copy is also present so the
# stale shadow never goes unnoticed.
#
# `reconcile --dry-run` is used as the probe: it triggers resolve_paths,
# reads state, mutates nothing, and exits 0. The WARNING is emitted from the
# `$gaia_state` (rung-1) branch, so its presence ALSO proves the canonical
# .gaia/state/ copy won the resolution.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SPRINT_STATE="$PLUGIN_ROOT/scripts/sprint-state.sh"
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

@test "issue #1109: WARNING when canonical .gaia/state/ and legacy impl-artifacts copy both exist" {
  _seed_canonical closed
  _seed_legacy active
  run env PROJECT_PATH="$TEST_TMP" bash "$SPRINT_STATE" reconcile --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "stale legacy sprint-status.yaml"
  echo "$output" | grep -F "remove it to avoid divergence"
}

@test "issue #1109: WARNING proves the canonical .gaia/state/ copy won (rung-1 branch)" {
  _seed_canonical closed
  _seed_legacy active
  run env PROJECT_PATH="$TEST_TMP" bash "$SPRINT_STATE" reconcile --dry-run
  [ "$status" -eq 0 ]
  # The warning is emitted only from the gaia_state (rung-1) branch — its
  # presence is proof the canonical copy was selected, not the stale legacy one.
  echo "$output" | grep -F "shadows the canonical .gaia/state/ copy"
}

@test "issue #1109: NO warning when only the canonical .gaia/state/ copy exists" {
  _seed_canonical closed
  run env PROJECT_PATH="$TEST_TMP" bash "$SPRINT_STATE" reconcile --dry-run
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF "stale legacy sprint-status.yaml"
}

@test "issue #1109: NO warning when impl-artifacts dir exists but holds no sprint-status.yaml" {
  _seed_canonical closed
  # Directory present (from setup) but no sprint-status.yaml inside it.
  run env PROJECT_PATH="$TEST_TMP" bash "$SPRINT_STATE" reconcile --dry-run
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF "stale legacy sprint-status.yaml"
}
