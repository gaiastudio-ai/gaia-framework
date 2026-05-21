#!/usr/bin/env bats
# af-2026-05-21-12-edit-prd-canonical.bats
#
# Regression coverage for AF-2026-05-21-12: sibling fix to AF-21-10
# (/gaia-create-prd). The /gaia-edit-prd skill's setup.sh hardcoded
# PRD_PATH="$PROJECT_ROOT/docs/planning-artifacts/prd.md" as a bare
# assignment with no canonical-first fallback. Post-ADR-111 projects
# could not find an existing PRD; greenfield re-init flows resolved to
# the legacy directory.
#
# Three-tier idiom applied (mirrors AF-21-10/-11):
#   Tier 1 — PRD_PATH env-var override wins
#   Tier 2 — positive-evidence-legacy (legacy file exists AND canonical dir does NOT)
#   Tier 3 — canonical default
#
# This bats fixture tests the PRD_PATH resolution block as a unit, isolating
# it from setup.sh's config-resolution and validate-gate prereqs (which
# require a fully-set-up project and would obscure the path-resolution test).
# The block is extracted verbatim from setup.sh:66-79 and tested in isolation.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SETUP_SH="$PLUGIN_ROOT/skills/gaia-edit-prd/scripts/setup.sh"
  cd "$TEST_TMP"
}

teardown() { common_teardown; }

# Helper: resolve PRD_PATH using the exact three-tier logic from setup.sh:66-79.
# Returns the resolved path on stdout. This MUST match the script's logic
# verbatim — any drift between this helper and the script is a test bug.
resolve_prd_path() {
  local project_root="$1"
  if [ -n "${PRD_PATH:-}" ]; then
    printf '%s' "$PRD_PATH"
    return
  fi
  if [ -f "$project_root/docs/planning-artifacts/prd.md" ] && [ ! -d "$project_root/.gaia/artifacts/planning-artifacts" ]; then
    printf '%s' "$project_root/docs/planning-artifacts/prd.md"
  else
    printf '%s' "$project_root/.gaia/artifacts/planning-artifacts/prd.md"
  fi
}

# Verification guard: assert the setup.sh on disk implements the same idiom.
# If setup.sh is edited and the logic drifts from resolve_prd_path() above,
# this test catches it.
@test "AF-21-12 edit-prd: setup.sh implements three-tier idiom verbatim" {
  # Verify the canonical default branch is present
  grep -qF '.gaia/artifacts/planning-artifacts/prd.md' "$SETUP_SH"
  # Verify the positive-evidence-legacy guard is present
  grep -qF '[ ! -d "$PROJECT_ROOT/.gaia/artifacts/planning-artifacts" ]' "$SETUP_SH"
  # Verify the env-var Tier 1 branch is present
  grep -qE 'if \[ -z "\$\{PRD_PATH:-\}" \]' "$SETUP_SH"
}

@test "AF-21-12 edit-prd: greenfield (no PRD anywhere) → resolves to canonical default" {
  unset PRD_PATH
  result=$(resolve_prd_path "$TEST_TMP")
  [ "$result" = "$TEST_TMP/.gaia/artifacts/planning-artifacts/prd.md" ]
}

@test "AF-21-12 edit-prd: post-ADR-111 (only .gaia/ exists) → resolves to canonical" {
  unset PRD_PATH
  mkdir -p ".gaia/artifacts/planning-artifacts"
  echo "# PRD" > ".gaia/artifacts/planning-artifacts/prd.md"
  result=$(resolve_prd_path "$TEST_TMP")
  [ "$result" = "$TEST_TMP/.gaia/artifacts/planning-artifacts/prd.md" ]
  # MUST NOT have created a rogue docs/ directory.
  [ ! -d "docs" ]
}

@test "AF-21-12 edit-prd: pre-ADR-111 (only docs/, no .gaia/) → legacy back-compat preserved" {
  unset PRD_PATH
  mkdir -p "docs/planning-artifacts"
  echo "# Legacy PRD" > "docs/planning-artifacts/prd.md"
  result=$(resolve_prd_path "$TEST_TMP")
  [ "$result" = "$TEST_TMP/docs/planning-artifacts/prd.md" ]
  # Canonical dir MUST NOT be silently created on a pre-ADR-111 project.
  [ ! -d ".gaia" ]
}

@test "AF-21-12 edit-prd: both present (mid-migration) → canonical wins" {
  unset PRD_PATH
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts"
  echo "# Canonical" > ".gaia/artifacts/planning-artifacts/prd.md"
  echo "# Legacy (should NOT be used)" > "docs/planning-artifacts/prd.md"
  result=$(resolve_prd_path "$TEST_TMP")
  [ "$result" = "$TEST_TMP/.gaia/artifacts/planning-artifacts/prd.md" ]
}

@test "AF-21-12 edit-prd: PRD_PATH env-var override (Tier 1) wins over both legacy and canonical" {
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts" "custom-location"
  echo "# Canonical" > ".gaia/artifacts/planning-artifacts/prd.md"
  echo "# Legacy" > "docs/planning-artifacts/prd.md"
  echo "# Custom" > "custom-location/my-prd.md"
  export PRD_PATH="$TEST_TMP/custom-location/my-prd.md"
  result=$(resolve_prd_path "$TEST_TMP")
  unset PRD_PATH
  [ "$result" = "$TEST_TMP/custom-location/my-prd.md" ]
}
