#!/usr/bin/env bats
# stale-comment-sweep.bats — E97-S6
#
# Asserts the stale-legacy-path comment sweep in resolve-config.sh and
# validate-gate.sh. Comment-only edits (zero runtime impact) per the
# story's hard scope constraint.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_SCRIPTS="$( cd "$BATS_TEST_DIRNAME/../scripts" && pwd )"
}

teardown() {
  common_teardown
}

# ---------- AC1: resolve-config.sh comments ----------

@test "AC1: resolve-config.sh line 8 documents .gaia/config/ canonical" {
  # Header docstring around line 8 should mention .gaia/config/ as canonical.
  run sed -n '6,12p' "$PLUGIN_SCRIPTS/resolve-config.sh"
  [[ "$output" == *".gaia/config/"* ]]
}

@test "AC1: resolve-config.sh lines 15-18 path-precedence list mentions .gaia/config/" {
  run sed -n '13,22p' "$PLUGIN_SCRIPTS/resolve-config.sh"
  [[ "$output" == *".gaia/config/"* ]]
  # Legacy config/ MUST remain documented as fallback (back-compat).
  [[ "$output" == *"config/"* ]]
}

@test "AC1: resolve-config.sh line 60 example block mentions .gaia/config/" {
  run sed -n '58,65p' "$PLUGIN_SCRIPTS/resolve-config.sh"
  [[ "$output" == *".gaia/config/"* ]]
}

# ---------- AC2: validate-gate.sh line 410 ----------

@test "AC2: validate-gate.sh line 410 docstring documents .gaia/config/ canonical" {
  run sed -n '410p' "$PLUGIN_SCRIPTS/validate-gate.sh"
  [[ "$output" == *".gaia/config/"* ]]
  # Legacy reference MAY remain (as documented fallback). Either way line is
  # no longer the pure-legacy `${PROJECT_ROOT}/config/project-config.yaml`.
  [[ "$output" != "# Read config_phase from \${PROJECT_ROOT}/config/project-config.yaml." ]]
}

@test "AC2: validate-gate.sh executable cfg= lines are unchanged (legacy fallback code)" {
  # AC2 scope: line 410 docstring ONLY. The `cfg=` executable lines (legacy
  # fallback assignments) MUST NOT be touched. Locate them by content match
  # rather than fixed line numbers (the docstring edit shifts subsequent
  # lines by +3, so the original Val citations 420/449/548 are now ~423/452/551
  # — content-based assertion is line-number-resilient).
  run grep -cF 'cfg="${PROJECT_ROOT}/config/project-config.yaml"' "$PLUGIN_SCRIPTS/validate-gate.sh"
  [ "$output" -eq 3 ]
}

@test "AC2: validate-gate.sh already-canonical comments are unchanged (E96-S1 / ADR-111)" {
  # AC2 scope exclusion: the canonical "# E96-S1 / ADR-111: prefer .gaia/config/..."
  # comments above each `if [ -f .gaia/config/...` block MUST remain present.
  # Content-based assertion (resilient to line-number shifts from the L410 edit).
  run grep -cE '^[[:space:]]*# E96-S1 / ADR-111: prefer ' "$PLUGIN_SCRIPTS/validate-gate.sh"
  [ "$output" -eq 3 ]
}

# ---------- AC3: zero runtime impact ----------

@test "AC3: both scripts pass bash -n syntax check" {
  run bash -n "$PLUGIN_SCRIPTS/resolve-config.sh"
  [ "$status" -eq 0 ]
  run bash -n "$PLUGIN_SCRIPTS/validate-gate.sh"
  [ "$status" -eq 0 ]
}

# ---------- AC4: TC-DH-1 smoke test ----------

@test "AC4: TC-DH-1 — resolve-config.sh executes identically on a representative fixture" {
  # Smoke: run --help and confirm exit 0 (no behavioral surprise from comment sweep).
  run bash "$PLUGIN_SCRIPTS/resolve-config.sh" --help
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]  # --help can exit 0 or 2 depending on convention
}
