#!/usr/bin/env bats
# af-2026-05-21-11-edit-arch-canonical.bats
#
# Regression coverage for AF-2026-05-21-11 (edit-arch half): /gaia-edit-arch's
# finalize.sh had the same hardcoded legacy fallback bug as the create-arch
# sibling. Same three-tier idiom fix applied.
#
# Covers the 4-quadrant matrix + Tier 1 env-var override (5 tests, parallel
# structure to af-2026-05-21-11-create-arch-canonical.bats).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FINALIZE="$PLUGIN_ROOT/skills/gaia-edit-arch/scripts/finalize.sh"
  cd "$TEST_TMP"
}

teardown() { common_teardown; }

run_finalize_and_capture_resolution() {
  unset ARCHITECTURE_ARTIFACT
  bash "$FINALIZE" 2>&1 || true
}

@test "edit-arch: greenfield (no architecture anywhere) → finalize.sh skips checklist gracefully" {
  [ ! -d ".gaia" ] && [ ! -d "docs" ]
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "no architecture artifact found"
  ! echo "$OUTPUT" | grep -qF "running 25-item checklist"
}

@test "edit-arch: post-migration (only .gaia/ exists) → resolves to canonical" {
  mkdir -p ".gaia/artifacts/planning-artifacts"
  cat > ".gaia/artifacts/planning-artifacts/architecture.md" <<'ARCH'
# Test Architecture
## Overview
test overview content
ARCH
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "running 25-item checklist against .gaia/artifacts/planning-artifacts/architecture.md"
  [ ! -d "docs" ]
}

@test "edit-arch: pre-migration (only docs/, no .gaia/) → legacy back-compat preserved" {
  mkdir -p "docs/planning-artifacts"
  cat > "docs/planning-artifacts/architecture.md" <<'ARCH'
# Legacy Architecture
## Overview
pre-ADR-111 project content
ARCH
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "running 25-item checklist against docs/planning-artifacts/architecture.md"
  [ ! -d ".gaia" ]
}

@test "edit-arch: both present (mid-migration) → canonical wins" {
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts"
  cat > ".gaia/artifacts/planning-artifacts/architecture.md" <<'ARCH'
# Canonical Architecture
ARCH
  cat > "docs/planning-artifacts/architecture.md" <<'ARCH'
# Legacy Architecture (should NOT be used)
ARCH
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "running 25-item checklist against .gaia/artifacts/planning-artifacts/architecture.md"
  ! echo "$OUTPUT" | grep -qF "running 25-item checklist against docs/planning-artifacts/architecture.md"
}

@test "edit-arch: ARCHITECTURE_ARTIFACT env-var override (Tier 1) wins over both legacy and canonical" {
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts"
  echo "# Canonical" > ".gaia/artifacts/planning-artifacts/architecture.md"
  echo "# Legacy" > "docs/planning-artifacts/architecture.md"
  mkdir -p "custom-location"
  echo "# Custom" > "custom-location/my-arch.md"
  export ARCHITECTURE_ARTIFACT="custom-location/my-arch.md"
  OUTPUT="$(bash "$FINALIZE" 2>&1 || true)"
  unset ARCHITECTURE_ARTIFACT
  echo "$OUTPUT" | grep -qF "running 25-item checklist against custom-location/my-arch.md"
}
