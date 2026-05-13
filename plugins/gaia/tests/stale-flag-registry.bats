#!/usr/bin/env bats
#
# stale-flag-registry.bats — E86-S6 / AC6.
#
# Covers `check-stale-flag-registry.sh`: static check that every
# `_memory/.*-stale` marker on disk is registered in the ADR-102
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
  mkdir -p "$FIXTURE_DIR/_memory" "$FIXTURE_DIR/docs/planning-artifacts/architecture"
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
| `_memory/.config-stale` | `ci-regen-stale-flag.sh` | CI workflow regeneration needed | `/gaia-config-ci --regenerate` |
| `_memory/.framework-version-stale` | drift detector | Run `/gaia-migrate` to reconcile | `/gaia-migrate` successful reconciliation |
MD
}

run_check() {
  run --separate-stderr env \
    CLAUDE_PROJECT_ROOT="$FIXTURE_DIR" \
    GAIA_MEMORY_PATH="$FIXTURE_DIR/_memory" \
    GAIA_REGISTRY_PATH="$REGISTRY" \
    bash "$SCRIPT"
}

# ===== TS-4 — Registered marker only → exit 0 =========================

@test "AC4 / TS-4: only registered markers in _memory/ → exit 0, no output" {
  : > "$FIXTURE_DIR/_memory/.config-stale"
  : > "$FIXTURE_DIR/_memory/.framework-version-stale"
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===== TS-5 — Unregistered marker → CRITICAL ==========================

@test "AC4 / TS-5: unregistered marker emits CRITICAL and exits non-zero" {
  : > "$FIXTURE_DIR/_memory/.bogus-stale"
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRITICAL: Unregistered stale-flag marker: _memory/.bogus-stale"* ]]
  [[ "$output" == *"Register in ADR-102 or remove"* ]]
}

# ===== TS-6 — No markers → exit 0 =====================================

@test "AC4 / TS-6: no .*-stale files in _memory/ → exit 0, no output" {
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===== TS-7 — Mixed registered + unregistered =========================

@test "AC4 / TS-7: mixed markers — CRITICAL fires only for unregistered" {
  : > "$FIXTURE_DIR/_memory/.config-stale"        # registered
  : > "$FIXTURE_DIR/_memory/.framework-version-stale"  # registered
  : > "$FIXTURE_DIR/_memory/.rogue-stale"         # unregistered
  : > "$FIXTURE_DIR/_memory/.other-stale"         # unregistered
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"_memory/.rogue-stale"* ]]
  [[ "$output" == *"_memory/.other-stale"* ]]
  # Registered markers MUST NOT appear in the CRITICAL list.
  ! [[ "$output" == *".config-stale. Register"* ]]
  ! [[ "$output" == *".framework-version-stale. Register"* ]]
}

# ===== TS-8 — Registry parsing ========================================

@test "AC6 / registry parsing: tolerates blank lines and header row" {
  # Append a second blank line + a trailing comment to ensure the parser
  # is not brittle to surrounding markdown.
  cat >> "$REGISTRY" <<'MD'

(Additional commentary that is not a registry row.)
MD
  : > "$FIXTURE_DIR/_memory/.config-stale"
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===== Defensive: nested markers under _memory/checkpoints/ ===========
# Per ADR-102 marker contract clause 3, markers MUST live at _memory/
# top level (-maxdepth 1). Nested markers under _memory/checkpoints/
# are deliberately out of scope for this check.

@test "AC4 / scope: nested markers under _memory/checkpoints/ are ignored" {
  mkdir -p "$FIXTURE_DIR/_memory/checkpoints"
  : > "$FIXTURE_DIR/_memory/checkpoints/.deep-stale"
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===== Defensive: missing registry file is a CRITICAL =================

@test "AC4 / missing-registry: absent registry file → CRITICAL, exit non-zero" {
  : > "$FIXTURE_DIR/_memory/.config-stale"
  rm "$REGISTRY"
  run_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRITICAL"* ]]
}

# ===== Structural: script declares the canonical maxdepth choice ======

@test "Structural: script documents the -maxdepth 1 scoping decision (Val W1)" {
  # Per Val plan-gate WARNING W1, the -maxdepth 1 scoping (ADR-102 clause 3)
  # must be documented inline so future maintainers don't widen the scope
  # accidentally.
  grep -qE "maxdepth 1.*ADR-102" "$SCRIPT"
}
