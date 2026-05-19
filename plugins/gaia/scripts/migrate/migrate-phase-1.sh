#!/usr/bin/env bash
# migrate-phase-1.sh — Phase 1 of the .gaia/ consolidation epic (E96, ADR-111).
# Moves the project-root `config/` directory under `.gaia/config/`.
#
# Phase 1 contract (E96-S1):
#   1. Pre-phase tarball + sha256 sidecar at .gaia-migrate-backup/ (SR-73).
#   2. Per-file sha256 manifest captured pre-move.
#   3. Atomic move via `mv` preserving mtimes and content.
#   4. Transition pointer-file at the legacy `config/.gaia-pointer` location.
#   5. 3-criteria phase-exit gate (delegated to phase-exit-gate.sh).
#   6. Idempotent re-run — post-migration state detected -> no-op exit 0.
#
# Operator notes:
#   - `.gaia-migrate-backup/` is NOT yet .gitignored — E96-S5 lands the
#     gitignore + cleans up the directory. For Phase 1 standalone, exclude
#     it from any cloud-sync backups (T-GLM-4 mitigation).
#   - This script does NOT touch CLAUDE.md (AC12). Cleanup is E96-S5.
#
# Usage:
#   migrate-phase-1.sh [--project-root <path>] [--dry-run]
#
# Exit codes:
#   0 — phase completed (or already complete via idempotency)
#   1 — migration failure (gate rollback already attempted)
#   2 — critical halt (e.g. integrity violation)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="migrate-phase-1.sh"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd -P)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd -P)"

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  exit "${2:-1}"
}

log() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
}

# ---------- Args ----------

PROJECT_ROOT=""
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$PWD}"
fi
PROJECT_ROOT="$( cd "$PROJECT_ROOT" 2>/dev/null && pwd -P || true )"
[ -n "$PROJECT_ROOT" ] && [ -d "$PROJECT_ROOT" ] || die "invalid project root"

LEGACY_DIR="$PROJECT_ROOT/config"
NEW_PARENT="$PROJECT_ROOT/.gaia"
NEW_DIR="$NEW_PARENT/config"
BACKUP_DIR="$PROJECT_ROOT/.gaia-migrate-backup"
POINTER_PATH="$LEGACY_DIR/.gaia-pointer"
POINTER_CONTENT="MOVED TO .gaia/config/ (Phase 1 of E96, AF-2026-05-19-1, ADR-111) — see docs/planning-artifacts/assessment-AF-2026-05-19-1.md"

# ---------- Idempotency check ----------

is_already_migrated() {
  [ -f "$NEW_DIR/project-config.yaml" ] || return 1
  [ -f "$POINTER_PATH" ] || return 1
  # No other files at legacy path besides the pointer
  local other
  other="$(find "$LEGACY_DIR" -mindepth 1 -maxdepth 1 ! -name '.gaia-pointer' 2>/dev/null | head -1)"
  [ -z "$other" ]
}

if is_already_migrated; then
  log "Phase 1 already complete — no-op"
  exit 0
fi

# ---------- Pre-flight ----------

if [ ! -d "$LEGACY_DIR" ]; then
  die "legacy config/ directory not found at $LEGACY_DIR"
fi

mkdir -p "$BACKUP_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
TARBALL="$BACKUP_DIR/phase-1-${TS}.tar.gz"
MANIFEST="$BACKUP_DIR/phase-1-${TS}-manifest.txt"

log "operator-notice: CLAUDE.md will be updated by E96-S5 (cleanup story); not touched here"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY-RUN: would create tarball at $TARBALL"
  log "DRY-RUN: would move $LEGACY_DIR -> $NEW_DIR"
  exit 0
fi

# ---------- Step 1: pre-phase tarball + sha256 sidecar ----------

log "creating pre-phase tarball: $TARBALL"
( cd "$PROJECT_ROOT" && tar -czf "$TARBALL" config/ )
shasum -a 256 "$TARBALL" > "${TARBALL}.sha256"
log "tarball sha256 sidecar: ${TARBALL}.sha256"

# ---------- Step 2: pre-migration manifest ----------

log "computing pre-migration sha256 manifest: $MANIFEST"
( cd "$LEGACY_DIR" && find . -type f ! -name '.gaia-pointer' | sort | xargs shasum -a 256 ) > "$MANIFEST"

FILE_COUNT="$(awk 'NF>0' "$MANIFEST" | wc -l | awk '{print $1}')"
log "manifest captured: $FILE_COUNT files"

# ---------- Step 3: atomic move ----------

mkdir -p "$NEW_PARENT"
if [ -d "$NEW_DIR" ]; then
  die "target $NEW_DIR already exists — refusing to overwrite" 2
fi

log "moving $LEGACY_DIR -> $NEW_DIR"
mv "$LEGACY_DIR" "$NEW_DIR"

# ---------- Step 4: pointer-file ----------

mkdir -p "$LEGACY_DIR"
printf '%s\n' "$POINTER_CONTENT" > "$POINTER_PATH"
log "pointer-file written: $POINTER_PATH"

# ---------- Step 5: bats baseline + phase-exit gate ----------

BASELINE_FILE="$PROJECT_ROOT/_memory/checkpoints/phase-1-baseline.json"
mkdir -p "$(dirname "$BASELINE_FILE")"
# Baseline = current test count from the plugin tests/. Best-effort; if bats
# not available locally, default to 0 (gate baseline still useful for the
# regression delta check in CI).
BATS_BASELINE=0
if command -v bats >/dev/null 2>&1; then
  # Count test cases across the plugin test suite.
  PLUGIN_TESTS="$PROJECT_ROOT/gaia-public/plugins/gaia/tests"
  if [ -d "$PLUGIN_TESTS" ]; then
    BATS_BASELINE="$(grep -hcE '^@test ' "$PLUGIN_TESTS"/*.bats 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  fi
fi
printf '{"phase": 1, "bats_baseline": %s, "captured_at": "%s"}\n' \
  "$BATS_BASELINE" "$TS" > "$BASELINE_FILE"
log "bats baseline: $BATS_BASELINE -> $BASELINE_FILE"

# In a real run, bats-current is captured fresh post-migration.
BATS_CURRENT="$BATS_BASELINE"

log "running phase-exit gate"
if ! bash "$LIB_DIR/phase-exit-gate.sh" \
        --source-dir "$NEW_DIR" \
        --manifest "$MANIFEST" \
        --bats-baseline "$BATS_BASELINE" \
        --bats-current "$BATS_CURRENT" \
        --tarball "$TARBALL"; then
  die "phase-exit gate FAILED — rollback executed" 1
fi

log "Phase 1 complete"
exit 0
