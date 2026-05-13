#!/usr/bin/env bats
# readiness-gate-negative.bats — E28-S48 gate enforcement negative tests (E28-S51 AC3)
#
# Verifies that gaia-readiness-check's setup.sh HALTs with clear errors when
# either traceability-matrix.md or ci-setup.md is missing. Each permutation is
# tested independently per ADR-042 (gates are enforced, not advisory).
#
# Usage:
#   bats tests/cluster-6-e2e/readiness-gate-negative.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"

  # Per-test isolated temp workspace (tmpdir pattern per story dev notes)
  TEST_TMP="$BATS_TEST_TMPDIR/gaia-readiness-neg-$$"
  mkdir -p "$TEST_TMP/checkpoints" "$TEST_TMP/memory" \
           "$TEST_TMP/docs/planning-artifacts" \
           "$TEST_TMP/docs/test-artifacts" \
           "$TEST_TMP/config"

  # Copy fixture config
  cp "$REPO_ROOT/tests/cluster-6-parity/fixture/config/project-config.yaml" \
     "$TEST_TMP/config/" 2>/dev/null || true

  # Set env overrides
  export GAIA_PROJECT_ROOT="$TEST_TMP"
  export GAIA_PROJECT_PATH="$TEST_TMP"
  export GAIA_MEMORY_PATH="$TEST_TMP/memory"
  export GAIA_CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  export GAIA_INSTALLED_PATH="$REPO_ROOT/plugins/gaia"
  export MEMORY_PATH="$TEST_TMP/memory"
  export CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  export PROJECT_ROOT="$TEST_TMP"
  export TEST_ARTIFACTS="$TEST_TMP/docs/test-artifacts"
  export CLAUDE_SKILL_DIR="$TEST_TMP"

  SKILL="gaia-readiness-check"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# Helper: run setup.sh (merge stderr into stdout for output capture)
run_setup() {
  local setup_script="$SKILLS_DIR/$SKILL/scripts/setup.sh"
  [ -x "$setup_script" ] || chmod +x "$setup_script"
  run bash "$setup_script" 2>&1
}

# ========== AC3: Missing traceability-matrix.md ==========

@test "AC3: setup.sh exits non-zero when traceability-matrix.md is missing" {
  # ci-setup.md exists, traceability-matrix.md does NOT
  echo "# CI Setup" > "$TEST_TMP/docs/test-artifacts/ci-setup.md"
  # Ensure traceability-matrix.md does not exist
  rm -f "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  run_setup
  [ "$status" -ne 0 ]
}

@test "AC3: error message names traceability-matrix when missing" {
  echo "# CI Setup" > "$TEST_TMP/docs/test-artifacts/ci-setup.md"
  rm -f "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  run_setup
  [[ "$output" == *"traceability"* ]]
}

@test "AC3: fixture state is unchanged after traceability-matrix HALT" {
  echo "# CI Setup" > "$TEST_TMP/docs/test-artifacts/ci-setup.md"
  rm -f "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  # Capture state before. Exclude _memory/ — that namespace is reserved for
  # ephemeral runtime markers (E86-S2 drift detection writes
  # .framework-version-checked-* and .framework-version-stale ambiently per
  # resolve-config.sh invocation; ADR-102 + AC9). The "fixture state
  # unchanged" intent is about the project-artifact tree, not the
  # gitignored runtime cache.
  local before_count
  before_count=$(find "$TEST_TMP" -type f -not -name '.framework-version-*' | wc -l | tr -d ' ')
  run_setup
  [ "$status" -ne 0 ]
  # Verify no new files were created (state unchanged)
  local after_count
  after_count=$(find "$TEST_TMP" -type f -not -name '.framework-version-*' | wc -l | tr -d ' ')
  [ "$before_count" -eq "$after_count" ]
}

# ========== AC3: Missing ci-setup.md ==========

@test "AC3: setup.sh exits non-zero when ci-setup.md is missing" {
  # traceability-matrix.md exists, ci-setup.md does NOT
  echo "# Traceability" > "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  rm -f "$TEST_TMP/docs/test-artifacts/ci-setup.md"
  run_setup
  [ "$status" -ne 0 ]
}

@test "AC3: error message names ci-setup when missing" {
  echo "# Traceability" > "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  rm -f "$TEST_TMP/docs/test-artifacts/ci-setup.md"
  run_setup
  [[ "$output" == *"ci-setup"* ]]
}

@test "AC3: fixture state is unchanged after ci-setup HALT" {
  echo "# Traceability" > "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  rm -f "$TEST_TMP/docs/test-artifacts/ci-setup.md"
  # See note above — exclude _memory/ from the unchanged-state check.
  local before_count
  before_count=$(find "$TEST_TMP" -type f -not -name '.framework-version-*' | wc -l | tr -d ' ')
  run_setup
  [ "$status" -ne 0 ]
  local after_count
  after_count=$(find "$TEST_TMP" -type f -not -name '.framework-version-*' | wc -l | tr -d ' ')
  [ "$before_count" -eq "$after_count" ]
}

# ========== AC3: Both missing ==========

@test "AC3: setup.sh exits non-zero when both are missing" {
  rm -f "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  rm -f "$TEST_TMP/docs/test-artifacts/ci-setup.md"
  run_setup
  [ "$status" -ne 0 ]
}

# ========== AC3: Positive — both present and non-empty ==========

@test "AC3-positive: setup.sh exits 0 when both prereqs exist" {
  echo "# Traceability" > "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  echo "# CI Setup" > "$TEST_TMP/docs/test-artifacts/ci-setup.md"
  run_setup
  [ "$status" -eq 0 ]
}

# ========== AC3: Idempotent re-run after prior HALT ==========

@test "AC3: setup.sh is idempotent after prior HALT" {
  # First run: HALT (missing traceability-matrix.md)
  echo "# CI Setup" > "$TEST_TMP/docs/test-artifacts/ci-setup.md"
  rm -f "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  run_setup
  [ "$status" -ne 0 ]

  # Create the missing file, re-run
  echo "# Traceability" > "$TEST_TMP/docs/test-artifacts/traceability-matrix.md"
  run_setup
  [ "$status" -eq 0 ]
}
