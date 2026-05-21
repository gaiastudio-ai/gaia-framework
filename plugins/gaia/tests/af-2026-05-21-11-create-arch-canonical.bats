#!/usr/bin/env bats
# af-2026-05-21-11-create-arch-canonical.bats
#
# Regression coverage for AF-2026-05-21-11 (create-arch half): /gaia-create-arch's
# finalize.sh hardcoded `docs/planning-artifacts/architecture.md` as its only
# fallback path. On greenfield post-ADR-111 projects the architecture
# document landed in a rogue `docs/` directory at project root instead of
# the canonical `.gaia/artifacts/planning-artifacts/architecture.md`. Same
# bug class as AF-21-10 (gaia-create-prd) but for the architecture cluster.
#
# The fix introduces a three-tier idiom (per AF-21-7's orchestration-warning.sh
# precedent and AF-21-10's gaia-create-prd/finalize.sh mirror):
#   Tier 1 — ARCHITECTURE_ARTIFACT env-var override wins when set.
#   Tier 2 — Positive pre-ADR-111 evidence (legacy file exists AND canonical
#            dir does NOT exist) → use legacy
#            `docs/planning-artifacts/architecture.md`.
#   Tier 3 — Canonical default: greenfield + post-ADR-111 projects route to
#            `.gaia/artifacts/planning-artifacts/architecture.md`.
#
# Covers the 4-quadrant matrix + Tier 1 env-var override.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FINALIZE="$PLUGIN_ROOT/skills/gaia-create-arch/scripts/finalize.sh"
  cd "$TEST_TMP"
}

teardown() { common_teardown; }

# Helper: run finalize.sh and capture which path it resolved ARTIFACT to.
run_finalize_and_capture_resolution() {
  unset ARCHITECTURE_ARTIFACT
  bash "$FINALIZE" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Greenfield — neither directory exists
# ---------------------------------------------------------------------------

@test "AF-21-11 create-arch: greenfield (no architecture anywhere) → finalize.sh skips checklist gracefully" {
  [ ! -d ".gaia" ] && [ ! -d "docs" ]
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "no architecture artifact found"
  ! echo "$OUTPUT" | grep -qF "running 33-item checklist"
}

# ---------------------------------------------------------------------------
# Post-ADR-111 — only canonical exists
# ---------------------------------------------------------------------------

@test "AF-21-11 create-arch: post-ADR-111 (only .gaia/ exists) → resolves to canonical" {
  mkdir -p ".gaia/artifacts/planning-artifacts"
  cat > ".gaia/artifacts/planning-artifacts/architecture.md" <<'ARCH'
# Test Architecture
## Overview
test overview content
ARCH
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "running 33-item checklist against .gaia/artifacts/planning-artifacts/architecture.md"
  # MUST NOT have created a rogue docs/ directory.
  [ ! -d "docs" ]
}

# ---------------------------------------------------------------------------
# Pre-ADR-111 — only legacy exists (positive-evidence guard fires)
# ---------------------------------------------------------------------------

@test "AF-21-11 create-arch: pre-ADR-111 (only docs/, no .gaia/) → legacy back-compat preserved" {
  mkdir -p "docs/planning-artifacts"
  cat > "docs/planning-artifacts/architecture.md" <<'ARCH'
# Legacy Architecture
## Overview
pre-ADR-111 project content
ARCH
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "running 33-item checklist against docs/planning-artifacts/architecture.md"
  # Canonical dir MUST NOT be silently created on a pre-ADR-111 project.
  [ ! -d ".gaia" ]
}

# ---------------------------------------------------------------------------
# Both present (mid-migration) — canonical wins (positive-evidence fails)
# ---------------------------------------------------------------------------

@test "AF-21-11 create-arch: both present (mid-migration) → canonical wins" {
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts"
  cat > ".gaia/artifacts/planning-artifacts/architecture.md" <<'ARCH'
# Canonical Architecture
## Overview
post-ADR-111 content
ARCH
  cat > "docs/planning-artifacts/architecture.md" <<'ARCH'
# Legacy Architecture (should NOT be used)
ARCH
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "running 33-item checklist against .gaia/artifacts/planning-artifacts/architecture.md"
  ! echo "$OUTPUT" | grep -qF "running 33-item checklist against docs/planning-artifacts/architecture.md"
}

# ---------------------------------------------------------------------------
# Env-var override (Tier 1) wins regardless of on-disk state
# ---------------------------------------------------------------------------

@test "AF-21-11 create-arch: ARCHITECTURE_ARTIFACT env-var override (Tier 1) wins over both legacy and canonical" {
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts"
  echo "# Canonical" > ".gaia/artifacts/planning-artifacts/architecture.md"
  echo "# Legacy" > "docs/planning-artifacts/architecture.md"
  mkdir -p "custom-location"
  echo "# Custom" > "custom-location/my-arch.md"
  export ARCHITECTURE_ARTIFACT="custom-location/my-arch.md"
  OUTPUT="$(bash "$FINALIZE" 2>&1 || true)"
  unset ARCHITECTURE_ARTIFACT
  echo "$OUTPUT" | grep -qF "running 33-item checklist against custom-location/my-arch.md"
}
