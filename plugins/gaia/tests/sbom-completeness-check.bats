#!/usr/bin/env bats
# sbom-completeness-check.bats — E104-S3 SBOM completeness assertion.
#
# Story: E104-S3. FR-543. ADR-078 (master flag + per-tool override).
#
# sbom-completeness-check.sh compares declared dependency count (from lock files)
# vs the cdxgen SBOM component count, and WARNs when abs(divergence_pct) exceeds
# 10% — or 15% when any of five per-ecosystem carve-outs auto-detects (Yarn Berry
# PnP, conda, Go vendor, Gradle no-lockfile, Gradle shadow/shade). NEVER aborts
# (NFR-84). Missing SBOM -> INFO skip (Val F1 — E70-S7 does not yet persist one).
# Pure bash + jq; offline; deterministic engineered fixtures.
#
# Env seams: SBOM_PROJECT_ROOT (repo to scan), SBOM_FILE (cdxgen sbom.json),
#            SBOM_REPORT (frontmatter report to populate).

load 'test_helper.bash'

setup() {
  common_setup
  CHK="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd 2>/dev/null || echo "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield")/sbom-completeness-check.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/sbom-completeness"
  export CHK FX
}
teardown() { common_teardown; }

run_chk() {
  local fixture="$1"
  PATH="$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_SBOM_COMPLETENESS_ENABLED=true \
    SBOM_PROJECT_ROOT="$FX/$fixture" SBOM_FILE="$FX/$fixture/sbom.json" run bash "$CHK"
}

# --- AC2 — npm 2% divergence: no WARNING (under 10%) ----------------------

@test "scenario 1): npm 2% divergence → no WARNING (under 10% default threshold)" {
  run_chk npm
  [ "$status" -eq 0 ]
  [[ "$output" != *"sbom_completeness_warning: true"* ]] && [[ "$output" != *"WARNING"* ]]
}

# --- AC2 — no-carve-out 11% divergence: WARNING @10% ----------------------

@test "scenario 8): no-carve-out 11% divergence → WARNING (10% threshold, no carve-outs)" {
  run_chk no-carve-out
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"applied_threshold=10"* ]]
  [[ "$output" == *"detected_carve_outs=[]"* ]] || [[ "$output" == *"detected_carve_outs:"* ]]
}

# --- AC2/AC5 — Yarn Berry PnP carve-out: 17% → WARNING @15% ----------------

@test "scenario 3): Yarn Berry PnP 17% → WARNING @15% (carve-out detected)" {
  run_chk yarn-berry-pnp
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"applied_threshold=15"* ]]
  [[ "$output" == *"yarn-berry-pnp"* ]]
}

# --- AC2/AC5 — conda carve-out: 12% → no WARNING (under 15%) ---------------

@test "scenario 6): conda 12% → no WARNING (carve-out applies, under 15%)" {
  run_chk conda
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
  [[ "$output" == *"conda"* ]]   # carve-out detected even though no WARNING
}

# --- AC2/AC5 — Go vendor carve-out: 8% → no WARNING -----------------------

@test "scenario 4): Go vendor 8% → no WARNING (carve-out applies)" {
  run_chk go-vendor
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
  [[ "$output" == *"go-vendor"* ]]
}

# --- AC2/AC5 — Gradle shadow carve-out: 18% → WARNING @15% ----------------

@test "scenario 5): Gradle shadow 18% → WARNING @15% (carve-out detected)" {
  run_chk gradle-shadow
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"gradle-shadow"* ]]
}

# --- AC2/AC5 — Gradle no-lockfile carve-out detection ---------------------

@test "scenario 12): Gradle without lockfile → carve-out detected (15% threshold)" {
  run_chk gradle-no-lockfile
  [ "$status" -eq 0 ]
  [[ "$output" == *"gradle-no-lockfile"* ]]
  [[ "$output" == *"applied_threshold=15"* ]]
}

# --- AC5 — multi-ecosystem: ANY carve-out → 15% ---------------------------

@test "scenario 7): multi-ecosystem (npm + Go vendor) → carve-out APPLIES (15%)" {
  run_chk multi-ecosystem
  [ "$status" -eq 0 ]
  [[ "$output" == *"applied_threshold=15"* ]]
  [[ "$output" == *"go-vendor"* ]]
}

# --- AC-X1 — flag-off skip ------------------------------------------------

@test "master flag off → check skipped (INFO, exit 0)" {
  PATH="$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=false \
    SBOM_PROJECT_ROOT="$FX/npm" SBOM_FILE="$FX/npm/sbom.json" run bash "$CHK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
}

# --- F1 (Val) — missing SBOM → INFO skip, never abort ---------------------

@test "F1): missing SBOM file → INFO skip, exit 0 (never aborts; producer unbuilt)" {
  PATH="$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_SBOM_COMPLETENESS_ENABLED=true \
    SBOM_PROJECT_ROOT="$FX/npm" SBOM_FILE="$TEST_TMP/does-not-exist.json" run bash "$CHK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO"* ]]
  [[ "$output" == *"SBOM"* ]]
  [[ "$output" != *"WARNING"* ]]
}

# --- AC3 — frontmatter fields populated on WARNING ------------------------

@test "WARNING run populates report frontmatter fields" {
  cat > "$TEST_TMP/report.md" <<'MD'
---
title: brownfield report
---
body
MD
  PATH="$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_SBOM_COMPLETENESS_ENABLED=true \
    SBOM_PROJECT_ROOT="$FX/no-carve-out" SBOM_FILE="$FX/no-carve-out/sbom.json" \
    SBOM_REPORT="$TEST_TMP/report.md" run bash "$CHK"
  [ "$status" -eq 0 ]
  run grep -E "^sbom_completeness_warning: true$" "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  run grep -E "^divergence_pct: 11$" "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  run grep -E "^applied_threshold: 10$" "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
}

# --- AC-X1 flag-resolution integration ------------------------------------

@test "resolve-config.sh --field brownfield.sbom_completeness_enabled is whitelisted" {
  cat > "$TEST_TMP/project-config.yaml" <<YAML
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/.gaia/memory
checkpoint_path: /tmp/gaia/.gaia/memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.176.0
date: 2026-05-25
brownfield:
  deterministic_tools: true
  sbom_completeness_enabled: true
YAML
  cp "$(cd "$BATS_TEST_DIRNAME/../config" && pwd)/project-config.schema.yaml" "$TEST_TMP/project-config.schema.yaml"
  run bash "$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/resolve-config.sh" \
    --shared "$TEST_TMP/project-config.yaml" --schema "$TEST_TMP/project-config.schema.yaml" \
    --field brownfield.sbom_completeness_enabled
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# --- Hygiene --------------------------------------------------------------

@test "sbom-completeness-check.sh exists, is executable, passes bash -n" {
  [ -x "$CHK" ]
  run bash -n "$CHK"
  [ "$status" -eq 0 ]
}
