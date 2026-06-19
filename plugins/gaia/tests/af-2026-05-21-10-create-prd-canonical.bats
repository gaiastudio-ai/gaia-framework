#!/usr/bin/env bats
# af-2026-05-21-10-create-prd-canonical.bats
#
# Regression coverage for AF-2026-05-21-10: /gaia-create-prd's finalize.sh
# hardcoded `docs/planning-artifacts/prd.md` as its only fallback path. On
# greenfield post-ADR-111 projects the PRD landed in a rogue `docs/`
# directory at project root instead of the canonical `.gaia/artifacts/
# planning-artifacts/prd.md`. Live repro 2026-05-21 via /gaia-create-prd
# on plugin v1.170.0.
#
# The fix introduces a three-tier idiom (per AF-21-7's orchestration-warning.sh
# precedent):
#   Tier 1 — PRD_ARTIFACT env-var override wins when set.
#   Tier 2 — Positive pre-ADR-111 evidence: legacy file exists AND canonical
#            dir does NOT exist → use legacy `docs/planning-artifacts/prd.md`.
#   Tier 3 — Canonical default: greenfield + post-ADR-111 projects route to
#            `.gaia/artifacts/planning-artifacts/prd.md`.
#
# This bats file covers the 3-quadrant matrix:
#   - greenfield (neither file) → ARTIFACT empty (no checklist runs)
#   - post-ADR-111 (only .gaia/) → canonical wins
#   - pre-ADR-111 (only docs/, no .gaia/) → legacy back-compat
#   - both present (mid-migration) → canonical wins (positive-evidence guard
#     fails because canonical dir EXISTS)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FINALIZE="$PLUGIN_ROOT/skills/gaia-create-prd/scripts/finalize.sh"
  cd "$TEST_TMP"
}

teardown() { common_teardown; }

# Helper: run finalize.sh and capture which path it resolved ARTIFACT to.
# The script logs `running 36-item checklist against <ARTIFACT>` when ARTIFACT
# resolves, or `no PRD artifact found ...` when it doesn't.
run_finalize_and_capture_resolution() {
  # Drop PRD_ARTIFACT so we exercise Tier 2/Tier 3 (Tier 1 has its own test).
  unset PRD_ARTIFACT
  bash "$FINALIZE" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Greenfield — neither directory exists
# ---------------------------------------------------------------------------

@test "greenfield (no PRD anywhere) → finalize.sh skips checklist gracefully" {
  [ ! -d ".gaia" ] && [ ! -d "docs" ]
  OUTPUT="$(run_finalize_and_capture_resolution)"
  # finalize.sh logs the skip message when ARTIFACT is empty.
  echo "$OUTPUT" | grep -qF "no PRD artifact found"
  # MUST NOT have run the checklist against a phantom legacy path.
  ! echo "$OUTPUT" | grep -qF "running 36-item checklist"
}

# ---------------------------------------------------------------------------
# Post-ADR-111 — only canonical exists (the dominant case post-migration)
# ---------------------------------------------------------------------------

@test "post-migration (only .gaia/ exists) → resolves to canonical" {
  mkdir -p ".gaia/artifacts/planning-artifacts"
  cat > ".gaia/artifacts/planning-artifacts/prd.md" <<'PRD'
# Test PRD
## Overview
test overview content
PRD
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "running 36-item checklist against .gaia/artifacts/planning-artifacts/prd.md"
  # MUST NOT have created a rogue docs/ directory.
  [ ! -d "docs" ]
}

# ---------------------------------------------------------------------------
# Pre-ADR-111 — only legacy exists (positive-evidence guard fires)
# ---------------------------------------------------------------------------

@test "pre-migration (only docs/, no .gaia/) → legacy back-compat preserved" {
  mkdir -p "docs/planning-artifacts"
  cat > "docs/planning-artifacts/prd.md" <<'PRD'
# Legacy PRD
## Overview
pre-ADR-111 project content
PRD
  OUTPUT="$(run_finalize_and_capture_resolution)"
  echo "$OUTPUT" | grep -qF "running 36-item checklist against docs/planning-artifacts/prd.md"
  # Canonical dir MUST NOT be silently created on a pre-ADR-111 project.
  [ ! -d ".gaia" ]
}

# ---------------------------------------------------------------------------
# Both present (mid-migration) — canonical wins (positive-evidence fails)
# ---------------------------------------------------------------------------

@test "both present (mid-migration) → canonical wins" {
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts"
  cat > ".gaia/artifacts/planning-artifacts/prd.md" <<'PRD'
# Canonical PRD
## Overview
post-ADR-111 content
PRD
  cat > "docs/planning-artifacts/prd.md" <<'PRD'
# Legacy PRD (should NOT be used)
PRD
  OUTPUT="$(run_finalize_and_capture_resolution)"
  # Canonical wins because positive-evidence guard fails on `! -d .gaia/...`.
  echo "$OUTPUT" | grep -qF "running 36-item checklist against .gaia/artifacts/planning-artifacts/prd.md"
  ! echo "$OUTPUT" | grep -qF "docs/planning-artifacts/prd.md"
}

# ---------------------------------------------------------------------------
# Env-var override (Tier 1) wins regardless of on-disk state
# ---------------------------------------------------------------------------

@test "PRD_ARTIFACT env-var override (Tier 1) wins over both legacy and canonical" {
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts"
  echo "# Canonical" > ".gaia/artifacts/planning-artifacts/prd.md"
  echo "# Legacy" > "docs/planning-artifacts/prd.md"
  mkdir -p "custom-location"
  echo "# Custom" > "custom-location/my-prd.md"
  export PRD_ARTIFACT="custom-location/my-prd.md"
  OUTPUT="$(bash "$FINALIZE" 2>&1 || true)"
  unset PRD_ARTIFACT
  echo "$OUTPUT" | grep -qF "running 36-item checklist against custom-location/my-prd.md"
}
