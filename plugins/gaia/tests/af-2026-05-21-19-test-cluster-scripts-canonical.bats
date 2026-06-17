#!/usr/bin/env bats
# af-2026-05-21-19-test-cluster-scripts-canonical.bats
#
# Regression coverage for AF-2026-05-21-19: script-side path-resolution
# canonicalization for the test cluster (deferred from AF-21-18).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_DESIGN_FINALIZE="$PLUGIN_ROOT/skills/gaia-test-design/scripts/finalize.sh"
  TEST_FRAMEWORK_FINALIZE="$PLUGIN_ROOT/skills/gaia-test-framework/scripts/finalize.sh"
  EDIT_TEST_PLAN_FINALIZE="$PLUGIN_ROOT/skills/gaia-edit-test-plan/scripts/finalize.sh"
  EDIT_TEST_PLAN_SETUP="$PLUGIN_ROOT/skills/gaia-edit-test-plan/scripts/setup.sh"
  ATDD_FINALIZE="$PLUGIN_ROOT/skills/gaia-atdd/scripts/finalize.sh"
  ATDD_RUN_RED="$PLUGIN_ROOT/skills/gaia-atdd/scripts/run-red-phase.sh"
  ATDD_DISCOVER="$PLUGIN_ROOT/skills/gaia-atdd/scripts/discover-stories.sh"
}

teardown() { common_teardown; }

# --- Display string canonicalization ---

@test "gaia-test-design/finalize.sh display string uses canonical path" {
  grep -qF 'Output file saved to .gaia/artifacts/test-artifacts/test-plan.md' "$TEST_DESIGN_FINALIZE"
  ! grep -qF 'Output file saved to docs/test-artifacts/test-plan.md' "$TEST_DESIGN_FINALIZE"
}

@test "gaia-edit-test-plan/finalize.sh display string uses canonical path" {
  grep -qF 'Output file saved to .gaia/artifacts/test-artifacts/test-plan.md' "$EDIT_TEST_PLAN_FINALIZE"
  ! grep -qF 'Output file saved to docs/test-artifacts/test-plan.md' "$EDIT_TEST_PLAN_FINALIZE"
}

@test "gaia-test-framework/finalize.sh remediation uses canonical path" {
  grep -qF '.gaia/artifacts/test-artifacts/test-framework-setup.md' "$TEST_FRAMEWORK_FINALIZE"
}

# --- Three-tier idiom assertions ---

@test "gaia-edit-test-plan/setup.sh implements three-tier idiom (TEST_PLAN_PATH)" {
  grep -qF '.gaia/artifacts/test-artifacts/test-plan.md' "$EDIT_TEST_PLAN_SETUP"
  grep -qE 'if \[ -z "\$\{TEST_PLAN_PATH:-\}" \]' "$EDIT_TEST_PLAN_SETUP"
  grep -qF '[ ! -d "$PROJECT_ROOT/.gaia/artifacts/test-artifacts" ]' "$EDIT_TEST_PLAN_SETUP"
}

@test "gaia-atdd/finalize.sh implements canonical-first with positive-evidence legacy" {
  grep -qF '.gaia/artifacts/test-artifacts/atdd-' "$ATDD_FINALIZE"
  grep -qE '\[ ! -d "\$derive_root/\.gaia/artifacts/test-artifacts" \]' "$ATDD_FINALIZE"
}

@test "gaia-atdd/run-red-phase.sh _BRIDGE_FILE uses canonical-first" {
  grep -qF '.gaia/artifacts/test-artifacts/test-environment.yaml' "$ATDD_RUN_RED"
  grep -qE '\[ ! -d "\$_PROJECT_ROOT/\.gaia/artifacts/test-artifacts" \]' "$ATDD_RUN_RED"
}

@test "gaia-atdd/discover-stories.sh docstring uses canonical path" {
  grep -qF '.gaia/artifacts/planning-artifacts/epics-and-stories.md' "$ATDD_DISCOVER"
  ! grep -qF 'Scans docs/planning-artifacts' "$ATDD_DISCOVER"
}
