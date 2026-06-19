#!/usr/bin/env bats
#
# stale-flag-registry.bats — E86-S6 / AC6.
#
# Covers `check-stale-flag-registry.sh`: static check that every
# `.gaia/memory/.*-stale` marker on disk is registered in the ADR-102
# registry table in the architecture document.
#
# Scenarios (per AC6 + Test Scenarios TS-4..TS-8):
#   - Registered marker only           → exit 0, no output
#   - Unregistered marker present      → CRITICAL emitted, exit non-zero
#   - No markers at all                → exit 0, no output
#   - Mixed registered + unregistered  → CRITICAL for unregistered only
#   - Registry parsing tolerates blank / header rows in the ADR-102 table

bats_require_minimum_version 1.5.0

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE_DIR/.gaia/memory" "$FIXTURE_DIR/docs/planning-artifacts/architecture"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-stale-flag-registry.sh"
  REGISTRY="$FIXTURE_DIR/docs/planning-artifacts/architecture/12-12-adr-detail-records.md"
  write_registry_canonical
}

write_registry_canonical() {
  # Minimal ADR-102 detail record with the canonical two-marker registry
  # table that the production architecture doc carries.
  cat > "$REGISTRY" <<'MD'
### ADR-102 — Stale-flag marker naming convention

**Initial Registry:**

| Marker | Owner | Purpose | Cleared By |
|--------|-------|---------|------------|
| `.gaia/memory/.config-stale` | `ci-regen-stale-flag.sh` | CI workflow regeneration needed | `/gaia-config-ci --regenerate` |
| `.gaia/memory/.framework-version-stale` | drift detector | Run `/gaia-migrate` to reconcile | `/gaia-migrate` successful reconciliation |
MD
}

write_registry_with_ground_truth() {
  # Canonical two-marker table PLUS the `.ground-truth-stale` row, mirroring
  # the exact `| Marker | Owner | Purpose | Cleared By |` column shape so the
  # scanner's first-column marker regex matches it generically.
  write_registry_canonical
  cat >> "$REGISTRY" <<'MD'
| `.gaia/memory/.ground-truth-stale` | `ground-truth-stale-check.sh` | Validator ground-truth.md is older than the newest planning/implementation artifact | `/gaia-refresh-ground-truth` successful refresh |
MD
}

run_check() {
  run --separate-stderr env \
    CLAUDE_PROJECT_ROOT="$FIXTURE_DIR" \
    GAIA_MEMORY_PATH="$FIXTURE_DIR/.gaia/memory" \
    GAIA_REGISTRY_PATH="$REGISTRY" \
    bash "$SCRIPT"
}

# ===== TS-4 — Registered marker only → exit 0 =========================

@test "only registered markers in .gaia/memory/ → exit 0, no output" {
  : > "$FIXTURE_DIR/.gaia/memory/.config-stale"
  : > "$FIXTURE_DIR/.gaia/memory/.framework-version-stale"
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===== TS-5 — Unregistered marker → CRITICAL ==========================

@test "unregistered marker emits CRITICAL and exits non-zero" {
  : > "$FIXTURE_DIR/.gaia/memory/.bogus-stale"
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRITICAL: Unregistered stale-flag marker: .gaia/memory/.bogus-stale"* ]]
  [[ "$output" == *"Register in the stale-flag registry or remove"* ]]
}

# ===== TS-6 — No markers → exit 0 =====================================

@test "no .*-stale files in .gaia/memory/ → exit 0, no output" {
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===== TS-7 — Mixed registered + unregistered =========================

@test "mixed markers — CRITICAL fires only for unregistered" {
  : > "$FIXTURE_DIR/.gaia/memory/.config-stale"        # registered
  : > "$FIXTURE_DIR/.gaia/memory/.framework-version-stale"  # registered
  : > "$FIXTURE_DIR/.gaia/memory/.rogue-stale"         # unregistered
  : > "$FIXTURE_DIR/.gaia/memory/.other-stale"         # unregistered
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *".gaia/memory/.rogue-stale"* ]]
  [[ "$output" == *".gaia/memory/.other-stale"* ]]
  # Registered markers MUST NOT appear in the CRITICAL list.
  ! [[ "$output" == *".config-stale. Register"* ]]
  ! [[ "$output" == *".framework-version-stale. Register"* ]]
}

# ===== TS-8 — Registry parsing ========================================

@test "registry parsing: tolerates blank lines and header row" {
  # Append a second blank line + a trailing comment to ensure the parser
  # is not brittle to surrounding markdown.
  cat >> "$REGISTRY" <<'MD'

(Additional commentary that is not a registry row.)
MD
  : > "$FIXTURE_DIR/.gaia/memory/.config-stale"
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===== Defensive: nested markers under .gaia/memory/checkpoints/ ===========
# Per ADR-102 marker contract clause 3, markers MUST live at .gaia/memory/
# top level (-maxdepth 1). Nested markers under .gaia/memory/checkpoints/
# are deliberately out of scope for this check.

@test "scope: nested markers under .gaia/memory/checkpoints/ are ignored" {
  mkdir -p "$FIXTURE_DIR/.gaia/memory/checkpoints"
  : > "$FIXTURE_DIR/.gaia/memory/checkpoints/.deep-stale"
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===== Defensive: missing registry file is a CRITICAL =================

@test "missing-registry: absent registry file → CRITICAL, exit non-zero" {
  : > "$FIXTURE_DIR/.gaia/memory/.config-stale"
  rm "$REGISTRY"
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRITICAL"* ]]
}

# ===== TC-GTS-18 — .ground-truth-stale registered → exit 0 ============

@test "registered .ground-truth-stale marker present → exit 0, no output" {
  write_registry_with_ground_truth
  : > "$FIXTURE_DIR/.gaia/memory/.ground-truth-stale"
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Negative companion — proves TC-GTS-18 would catch a silent de-registration:
# the marker on disk but NO ground-truth row in the registry → CRITICAL.
@test "guard: .ground-truth-stale marker NOT in registry → CRITICAL, exit non-zero" {
  write_registry_canonical   # canonical table only — no ground-truth row
  : > "$FIXTURE_DIR/.gaia/memory/.ground-truth-stale"
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRITICAL: Unregistered stale-flag marker: .gaia/memory/.ground-truth-stale"* ]]
}

# ===== Structural: script declares the canonical maxdepth choice ======

@test "Structural: script documents the -maxdepth 1 scoping decision (Val W1)" {
  # Per Val plan-gate WARNING W1, the -maxdepth 1 scoping (ADR-102 clause 3)
  # must be documented inline so future maintainers don't widen the scope
  # accidentally.
  grep -qE "maxdepth 1.*marker contract clause 3" "$SCRIPT"
}
