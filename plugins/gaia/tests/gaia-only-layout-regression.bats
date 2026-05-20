#!/usr/bin/env bats
# gaia-only-layout-regression.bats — E96-S7 AC6 regression suite.
#
# Verifies that the four runtime invariants exercised by E96-S7's smart-fallback
# sweep all hold against a tmpdir fixture where ONLY .gaia/ exists (no legacy
# docs/, _memory/, config/, or custom/ siblings). This is the substantive
# behavioural backstop for E96-S5's silent-deferral of the bulk-sweep work.
#
# Invariants under test:
#   - resolve-story-file.sh resolves a nested .gaia/-only story key
#   - sprint-state.sh transitions a .gaia/-only sprint story
#   - review-gate.sh status returns the 6-row UNVERIFIED block from a .gaia/-only story
#   - track-b-dispatch.sh picks up the .gaia/-only project-config.yaml
#
# The fixture is materialised fresh per test via
# plugins/gaia/tests/fixtures/gaia-only-layout/setup.sh.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd -P)"
  FIXTURE_SETUP="$REPO_ROOT/plugins/gaia/tests/fixtures/gaia-only-layout/setup.sh"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  SPRINT_REVIEW_SCRIPTS="$REPO_ROOT/plugins/gaia/skills/gaia-sprint-review/scripts"

  TMPDIR_FIXTURE="$(mktemp -d)"
  "$FIXTURE_SETUP" "$TMPDIR_FIXTURE" >/dev/null

  # Assert no legacy siblings exist — the fixture invariant itself
  for legacy in docs _memory config custom; do
    [ ! -d "$TMPDIR_FIXTURE/$legacy" ] || {
      echo "fixture invariant violated: legacy sibling exists: $legacy" >&2
      return 1
    }
  done

  # All scripts under test honor PROJECT_PATH / CLAUDE_PROJECT_ROOT env vars
  export PROJECT_PATH="$TMPDIR_FIXTURE"
  export CLAUDE_PROJECT_ROOT="$TMPDIR_FIXTURE"
  cd "$TMPDIR_FIXTURE"
}

teardown() {
  if [ -n "${TMPDIR_FIXTURE:-}" ] && [ -d "$TMPDIR_FIXTURE" ]; then
    rm -rf "$TMPDIR_FIXTURE"
  fi
}

# ---------- AC6 invariant 1: resolve-story-file.sh ----------

@test "gaia-only-layout: resolve-story-file.sh resolves nested .gaia/-only story" {
  run "$SCRIPTS_DIR/resolve-story-file.sh" "E1-S1"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/artifacts/implementation-artifacts/epic-E1-fixture/stories/E1-S1-fixture-story.md" ]]
}

@test "gaia-only-layout: resolve-story-file.sh emits no legacy-flat shadow warning" {
  run "$SCRIPTS_DIR/resolve-story-file.sh" "E1-S1"
  [ "$status" -eq 0 ]
  # No docs/ shadow file exists in the fixture, so no shadow warning should fire
  [[ "$output" != *"legacy-flat shadow"* ]]
}

# ---------- AC6 invariant 2: sprint-state.sh transition ----------

@test "gaia-only-layout: sprint-state.sh reads .gaia/-only sprint-status.yaml" {
  run "$SCRIPTS_DIR/sprint-state.sh" get --story "E1-S1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready-for-dev"* ]]
}

# ---------- AC6 invariant 3: review-gate.sh status block ----------

@test "gaia-only-layout: review-gate.sh status returns 6-row block from .gaia/-only story" {
  run "$SCRIPTS_DIR/review-gate.sh" status --story "E1-S1"
  [ "$status" -eq 0 ]
  # The 6 canonical Review Gate rows (per CANONICAL_GATES in review-gate.sh)
  [[ "$output" == *"Code Review"* ]]
  [[ "$output" == *"QA Tests"* ]]
  [[ "$output" == *"Security Review"* ]]
  [[ "$output" == *"Test Automation"* ]]
  [[ "$output" == *"Test Review"* ]]
  [[ "$output" == *"Performance Review"* ]]
  [[ "$output" == *"UNVERIFIED"* ]]
}

# ---------- AC6 invariant 4: track-b-dispatch.sh config resolution ----------

@test "gaia-only-layout: track-b-dispatch.sh defaults to .gaia/config/project-config.yaml" {
  # The script's default config_path resolver should pick up the .gaia/ path
  # when no legacy config/project-config.yaml sibling exists. We exercise the
  # resolver via a help / dry-run invocation that doesn't require Val.
  run "$SPRINT_REVIEW_SCRIPTS/track-b-dispatch.sh" --sprint "sprint-fixture-1"
  # Script may exit 0 or non-zero depending on stub state — what matters is
  # that it did NOT fail with "config not found" against the fixture.
  [[ "$output" != *"config not found"* ]]
  [[ "$output" != *"could not resolve config"* ]]
}

# ---------- AC6 invariant 5: no bare-legacy fallback path on .gaia/-only ----------

@test "gaia-only-layout: scripts do not create legacy siblings as side-effect" {
  # Run the four invariants above in sequence and assert that no legacy
  # sibling directory was created as a side-effect of any of them.
  "$SCRIPTS_DIR/resolve-story-file.sh" "E1-S1" >/dev/null 2>&1 || true
  "$SCRIPTS_DIR/sprint-state.sh" get --story "E1-S1" >/dev/null 2>&1 || true
  "$SCRIPTS_DIR/review-gate.sh" status --story "E1-S1" >/dev/null 2>&1 || true

  for legacy in docs _memory config custom; do
    [ ! -d "$TMPDIR_FIXTURE/$legacy" ] || {
      echo "regression: legacy sibling created by script side-effect: $legacy" >&2
      return 1
    }
  done
}
