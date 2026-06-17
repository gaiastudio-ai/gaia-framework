#!/usr/bin/env bats
# af-2026-05-21-8-greenfield-no-rogue-config.bats
#
# Regression coverage for AF-2026-05-21-8: 4 install/migration scripts
# defaulted to legacy `config/` path on greenfield projects, creating a
# rogue `config/` directory at project root before /gaia-init had a chance
# to bootstrap `.gaia/config/`. Live repro 2026-05-21 via /gaia:gaia-init
# on plugin v1.167.0.
#
# Sibling AF to AF-2026-05-21-7 (which fixed the same bug class for the
# `_memory/` directory). Together the two AFs close the .gaia/
# consolidation's greenfield-bootstrap gap end-to-end.
#
# Covers the 3-quadrant matrix for the 4 modified scripts:
#   - greenfield (neither dir exists)        → canonical .gaia/config/ wins
#   - post-ADR-111 (only .gaia/config/ exists) → canonical wins
#   - pre-ADR-111 (only config/ exists, no .gaia/) → legacy back-compat
#
# Plus a 4th quadrant per AF-21-7 precedent (both dirs present → canonical
# wins, positive-evidence guard fails on the `! -d .gaia/config` clause).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  EXAMPLE_HELPER="${PLUGIN_ROOT}/scripts/install-test-environment-example.sh"
  MANIFEST_HELPER="${PLUGIN_ROOT}/scripts/install-test-environment-manifest.sh"
  GENERATOR="${PLUGIN_ROOT}/scripts/lib/test-environment-manifest.sh"
  MIGRATE_HELPER="${PLUGIN_ROOT}/scripts/migrate-test-environment-path.sh"
  cd "$TEST_TMP"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# install-test-environment-example.sh — Category A install script
# ---------------------------------------------------------------------------

@test "install-test-environment-example.sh: greenfield → canonical .gaia/config/" {
  [ ! -d "config" ] && [ ! -d ".gaia/config" ]
  run bash "$EXAMPLE_HELPER" --target "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ -f ".gaia/config/test-environment.yaml.example" ]
  # Regression guard: no rogue config/ dir at project root.
  [ ! -d "config" ]
}

@test "install-test-environment-example.sh: pre-migration (only config/) → legacy honored" {
  mkdir -p "config"
  run bash "$EXAMPLE_HELPER" --target "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ -f "config/test-environment.yaml.example" ]
  # Pre-ADR-111 project keeps legacy layout, no canonical dir created.
  [ ! -d ".gaia/config" ]
}

@test "install-test-environment-example.sh: post-migration (only .gaia/config/) → canonical wins" {
  mkdir -p ".gaia/config"
  run bash "$EXAMPLE_HELPER" --target "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ -f ".gaia/config/test-environment.yaml.example" ]
  [ ! -d "config" ]
}

@test "install-test-environment-example.sh: both dirs present → canonical wins" {
  mkdir -p "config" ".gaia/config"
  run bash "$EXAMPLE_HELPER" --target "$TEST_TMP"
  [ "$status" -eq 0 ]
  # Canonical chosen because `! -d .gaia/config` is false.
  [ -f ".gaia/config/test-environment.yaml.example" ]
  [ ! -f "config/test-environment.yaml.example" ]
}

# ---------------------------------------------------------------------------
# lib/test-environment-manifest.sh — F3 sequencing-critical site
# ---------------------------------------------------------------------------

@test "lib/test-environment-manifest.sh: greenfield --write → canonical .gaia/config/" {
  echo '{"name":"test","devDependencies":{"jest":"^29.0.0"}}' > "$TEST_TMP/package.json"
  run bash "$GENERATOR" --target "$TEST_TMP" --write
  [ "$status" -eq 0 ]
  [ -f ".gaia/config/test-environment.yaml" ]
  [ ! -d "config" ]
}

@test "lib/test-environment-manifest.sh: pre-migration + existing legacy file → short-circuit preserves it (sequencing)" {
  # This is the F3 CRITICAL sequencing test — the canonical-default guard
  # MUST resolve MANIFEST_REL BEFORE the line-77 copy-if-absent short-circuit,
  # so a legacy user's existing file is preserved (not shadowed).
  mkdir -p "config"
  echo "# user-edited legacy manifest" > "config/test-environment.yaml"
  USER_HASH=$(shasum -a 256 "config/test-environment.yaml" | awk '{print $1}')

  echo '{"name":"test"}' > "$TEST_TMP/package.json"
  run bash "$GENERATOR" --target "$TEST_TMP" --write
  [ "$status" -eq 0 ]

  # Legacy file preserved byte-identical.
  POST_HASH=$(shasum -a 256 "config/test-environment.yaml" | awk '{print $1}')
  [ "$USER_HASH" = "$POST_HASH" ]
  # Canonical NOT created (legacy branch taken on positive evidence).
  [ ! -f ".gaia/config/test-environment.yaml" ]
}

# ---------------------------------------------------------------------------
# install-test-environment-manifest.sh — Category A sibling
# ---------------------------------------------------------------------------

@test "install-test-environment-manifest.sh: greenfield → canonical .gaia/config/" {
  # First materialize the .example template via the install helper.
  run bash "$EXAMPLE_HELPER" --target "$TEST_TMP"
  [ "$status" -eq 0 ]
  # Then copy .example → .yaml via the manifest installer.
  run bash "$MANIFEST_HELPER" --target "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ -f ".gaia/config/test-environment.yaml" ]
  [ -f ".gaia/config/test-environment.yaml.example" ]
  [ ! -d "config" ]
}

# ---------------------------------------------------------------------------
# migrate-test-environment-path.sh — Category A migration helper
# ---------------------------------------------------------------------------

@test "migrate-test-environment-path.sh: greenfield no-op → no rogue config/ or _memory/" {
  run bash "$MIGRATE_HELPER" --target "$TEST_TMP"
  [ "$status" -eq 0 ]
  # No legacy file to migrate — script no-ops.
  [ ! -d "config" ]
  [ ! -d "_memory" ]
}

@test "migrate-test-environment-path.sh: legacy file on greenfield-y project → moves to canonical .gaia/config/" {
  # docs/test-artifacts/ legacy file present; nothing else (no .gaia/, no config/, no _memory/).
  mkdir -p "docs/test-artifacts"
  echo "version: 2" > "docs/test-artifacts/test-environment.yaml"

  run bash "$MIGRATE_HELPER" --target "$TEST_TMP"
  [ "$status" -eq 0 ]

  # Moved to canonical (.gaia/config/), NOT to legacy (config/).
  [ -f ".gaia/config/test-environment.yaml" ]
  [ ! -d "config" ]
  # Legacy source removed after move.
  [ ! -f "docs/test-artifacts/test-environment.yaml" ]
  # Sentinel landed in canonical .gaia/memory/.
  [ -f ".gaia/memory/.test-environment-path-migrated" ]
  [ ! -d "_memory" ]
}
