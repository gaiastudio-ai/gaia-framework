#!/usr/bin/env bats
# e28-s199-ci-finalize-gate.bats — regression coverage for E28-S199
# (Fix CI finalize-gate conditionality — skip ci_setup_exists on runs that
# did not produce output).
#
# The current behavior (pre-S199) of gaia-ci-setup/finalize.sh and
# gaia-ci-edit/finalize.sh unconditionally calls validate-gate.sh
# ci_setup_exists. On a fresh fixture the check fails and finalize
# exits 1, which masks real errors and blocks clean-fixture runs.
#
# Post-S199 behavior:
#   - gaia-ci-setup/finalize.sh  — the ci_setup_exists post-check is removed
#     outright (the skill is the producer; the gate is tautological). The
#     finalize script now exits 0 on fresh-fixture.
#   - gaia-ci-edit/finalize.sh    — keeps the ci_setup_exists gate as a
#     regression guard but gates it on a "had prior setup" marker file
#     written by gaia-ci-edit/setup.sh. Fresh-fixture → no marker → gate
#     skipped → exit 0. Prior-setup-existed → marker present → gate runs
#     and fails non-zero if the edit erased the file.
#
# Refs: E28-S199 story, E28-S197 triage findings (F3 / ContractBug).

load 'test_helper.bash'

# Resolve plugin skill paths (tests live two levels under the plugin root).
PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
CI_SETUP_FINALIZE="$PLUGIN_ROOT/skills/gaia-ci-setup/scripts/finalize.sh"
CI_SETUP_SETUP="$PLUGIN_ROOT/skills/gaia-ci-setup/scripts/setup.sh"
CI_EDIT_FINALIZE="$PLUGIN_ROOT/skills/gaia-ci-edit/scripts/finalize.sh"
CI_EDIT_SETUP="$PLUGIN_ROOT/skills/gaia-ci-edit/scripts/setup.sh"

setup() {
  common_setup
  # Create an isolated fresh fixture root. No project-config.yaml, no
  # global.yaml, no docs/ tree — this simulates "the skill was invoked on
  # a fresh project where nothing has been produced yet."
  FIXTURE="$TEST_TMP/fresh-fixture"
  mkdir -p "$FIXTURE/config"
  # Minimal global.yaml so resolve-config.sh succeeds. Fields populated to
  # satisfy resolve-config.sh's required-field validation; what matters
  # downstream is that $PWD is $FIXTURE so validate-gate.sh's relative
  # "docs/test-artifacts/ci-setup.md" resolves under FIXTURE.
  printf '%s\n' \
    'project_name: e28-s199-fixture' \
    'project_root: .' \
    'project_path: .' \
    'memory_path: _memory' \
    'checkpoint_path: _memory/checkpoints' \
    'installed_path: _gaia' \
    'framework_version: test' \
    'date: 2026-04-19' \
    > "$FIXTURE/config/global.yaml"
  mkdir -p "$FIXTURE/_memory/checkpoints"
  # PROJECT_ROOT governs where the finalize scripts' resolved paths point.
  export PROJECT_ROOT="$FIXTURE"
  export CLAUDE_PROJECT_ROOT="$FIXTURE"
  # Downstream foundation scripts (checkpoint.sh) require CHECKPOINT_PATH
  # in the environment when invoked outside the plugin harness — the
  # resolve-config.sh fallback only activates when CLAUDE_SKILL_DIR is set
  # by the harness. Set it explicitly so checkpoint.sh writes into the
  # fixture temp dir rather than failing and masking the finalize exit.
  export CHECKPOINT_PATH="$FIXTURE/_memory/checkpoints"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC3 — gaia-ci-setup/finalize.sh exits 0 on fresh fixture (no produced file).
# ---------------------------------------------------------------------------
@test "gaia-ci-setup/finalize.sh: fresh fixture exits 0 (no ci-setup.md produced)" {
  # Fresh fixture: no docs/test-artifacts/ci-setup.md exists.
  cd "$FIXTURE"
  run bash "$CI_SETUP_FINALIZE"
  [ "$status" -eq 0 ]
  # Must NOT halt on the tautological post-check.
  [[ "$output" != *"ci_setup_exists gate failed"* ]]
}

# ---------------------------------------------------------------------------
# AC2 — gaia-ci-setup/finalize.sh exits 0 on a successful run where the body
# DID write docs/test-artifacts/ci-setup.md.
# ---------------------------------------------------------------------------
@test "gaia-ci-setup/finalize.sh: successful run with produced file exits 0" {
  mkdir -p "$FIXTURE/docs/test-artifacts"
  # AF-2026-05-27-8 / Test06 F-010: finalize.sh now defaults CI_SETUP_ARTIFACT to
  # the resolved ci-setup.md and RUNS its SV-01..06 checklist when the env var is
  # unset (previously it skipped, so a stub `placeholder` sufficed for exit 0).
  # A "successful run" produces a COMPLETE ci-setup.md — seed one so the checklist
  # passes and finalize exits 0, preserving the AC2 "successful run exits 0" intent.
  cat > "$FIXTURE/docs/test-artifacts/ci-setup.md" <<'CISETUP'
# CI Setup

## Pipeline Stages
build, lint, test, coverage stages defined.

## Quality Gates
Coverage target 80%; pass rate threshold enforced.

## Secrets Management
Required secrets and per-environment separation documented.

## Deployment Strategy
staging then production, with rollback on failure.

## Monitoring and Notifications
Failure alerts via webhook/slack and a status badge.

## Pipeline Config
Generated pipeline config committed.
CISETUP
  cd "$FIXTURE"
  run bash "$CI_SETUP_FINALIZE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5 — gaia-ci-edit/finalize.sh exits 0 on fresh fixture (no prior setup).
# ---------------------------------------------------------------------------
@test "gaia-ci-edit/finalize.sh: fresh fixture (no prior setup) exits 0" {
  # Fresh fixture: no docs/test-artifacts/ci-setup.md and no had_prior_setup
  # marker under .gaia/run-state/. The finalize script must detect that no
  # prior setup was observed and skip the ci_setup_exists gate.
  cd "$FIXTURE"
  run bash "$CI_EDIT_FINALIZE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ci_setup_exists gate failed"* ]]
}

# ---------------------------------------------------------------------------
# AC6 — gaia-ci-edit/finalize.sh exits non-zero when a prior setup existed
# and the edit erased it (the regression guard still triggers).
# ---------------------------------------------------------------------------
@test "gaia-ci-edit/finalize.sh: prior setup erased by edit exits non-zero" {
  # Seed the "had prior setup" marker — setup.sh writes this when it
  # observes docs/test-artifacts/ci-setup.md at invocation time. The test
  # stages the marker directly so the test does not depend on setup.sh
  # order-of-operations.
  mkdir -p "$FIXTURE/.gaia/run-state"
  : > "$FIXTURE/.gaia/run-state/ci-edit-had-prior-setup"
  # The edit erased ci-setup.md — the file is NOT present at finalize time.
  # finalize.sh must invoke validate-gate.sh ci_setup_exists which fails.
  cd "$FIXTURE"
  run bash "$CI_EDIT_FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ci_setup_exists gate failed"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — gaia-ci-edit/finalize.sh with prior setup STILL PRESENT exits 0.
# ---------------------------------------------------------------------------
@test "gaia-ci-edit/finalize.sh: prior setup preserved by edit exits 0" {
  # Marker present AND the setup file still exists after the edit.
  mkdir -p "$FIXTURE/.gaia/run-state"
  : > "$FIXTURE/.gaia/run-state/ci-edit-had-prior-setup"
  mkdir -p "$FIXTURE/docs/test-artifacts"
  printf 'preserved\n' > "$FIXTURE/docs/test-artifacts/ci-setup.md"
  cd "$FIXTURE"
  run bash "$CI_EDIT_FINALIZE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Contract — gaia-ci-edit/setup.sh writes the had_prior_setup marker when
# docs/test-artifacts/ci-setup.md is present at invocation time.
# ---------------------------------------------------------------------------
@test "gaia-ci-edit/setup.sh: writes had_prior_setup marker when ci-setup.md exists" {
  mkdir -p "$FIXTURE/docs/test-artifacts"
  printf 'prior\n' > "$FIXTURE/docs/test-artifacts/ci-setup.md"
  cd "$FIXTURE"
  run bash "$CI_EDIT_SETUP"
  [ "$status" -eq 0 ]
  [ -f "$FIXTURE/.gaia/run-state/ci-edit-had-prior-setup" ]
}

# ---------------------------------------------------------------------------
# Contract — gaia-ci-edit/setup.sh does NOT write the marker when no prior
# setup file exists (fresh fixture).
# ---------------------------------------------------------------------------
@test "gaia-ci-edit/setup.sh: no marker written when ci-setup.md absent" {
  cd "$FIXTURE"
  run bash "$CI_EDIT_SETUP"
  [ "$status" -eq 0 ]
  [ ! -f "$FIXTURE/.gaia/run-state/ci-edit-had-prior-setup" ]
}
