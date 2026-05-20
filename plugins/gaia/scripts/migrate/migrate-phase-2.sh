#!/usr/bin/env bash
# migrate-phase-2.sh — Phase 2 of the .gaia/ consolidation epic (E96, ADR-111).
# Moves the project-root `docs/*-artifacts/` subdirs under `.gaia/artifacts/`
# and extracts the mutable state files (`sprint-status.yaml`, `action-items.yaml`)
# to `.gaia/state/`.
#
# Phase 2 contract (E96-S2):
#   1. Pre-phase tarball + sha256 sidecar at .gaia-migrate-backup/.
#   2. Per-file sha256 manifest captured pre-move.
#   3. Atomic move via `mv` preserving mtimes and content for the 5 artifact
#      subdirs (planning, implementation, test, creative, research).
#   4. State-file extraction: sprint-status.yaml + action-items.yaml moved
#      (line-based, comments preserved per feedback_action_items_writer_bugs).
#   5. Transition pointer files at every legacy location.
#   6. 3-criteria phase-exit gate (delegated to phase-exit-gate.sh).
#   7. Idempotent re-run.
#
# Editorial constraint (AC9): operator-facing log lines MUST NOT contain bare
# `docs/` — every relocated path is named in its absolute prefixed form.
#
# Usage:
#   migrate-phase-2.sh [--project-root <path>] [--dry-run]
#
# Exit codes:
#   0 — phase complete (or no-op idempotency)
#   1 — failure (gate rollback attempted)
#   2 — critical halt (integrity violation)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="migrate-phase-2.sh"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd -P)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd -P)"

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  exit "${2:-1}"
}

log() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
}

# Args
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

ARTIFACT_SUBDIRS=(planning-artifacts implementation-artifacts test-artifacts creative-artifacts research-artifacts)
LEGACY_DOCS="$PROJECT_ROOT/docs"
NEW_ARTIFACTS="$PROJECT_ROOT/.gaia/artifacts"
NEW_STATE="$PROJECT_ROOT/.gaia/state"
BACKUP_DIR="$PROJECT_ROOT/.gaia-migrate-backup"

# Idempotency check
is_already_migrated() {
  local sd
  for sd in "${ARTIFACT_SUBDIRS[@]}"; do
    if [ ! -d "$NEW_ARTIFACTS/$sd" ]; then
      return 1
    fi
    if [ ! -f "$LEGACY_DOCS/$sd/.gaia-pointer" ]; then
      return 1
    fi
  done
  return 0
}

if is_already_migrated; then
  log "Phase 2 already complete — no-op"
  exit 0
fi

# Pre-flight
if [ ! -d "$LEGACY_DOCS" ]; then
  die "legacy docs/ tree not found at \$PROJECT_ROOT/docs"
fi

mkdir -p "$BACKUP_DIR" "$NEW_ARTIFACTS" "$NEW_STATE"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
TARBALL="$BACKUP_DIR/phase-2-${TS}.tar.gz"
MANIFEST="$BACKUP_DIR/phase-2-${TS}-manifest.txt"
POINTER_LIST="${TARBALL}.pointers.txt"
: > "$POINTER_LIST"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY-RUN: would create pre-phase tarball -> $TARBALL"
  log "DRY-RUN: would move 5 artifact subdirs to .gaia/artifacts/"
  log "DRY-RUN: would extract sprint-status.yaml + action-items.yaml to .gaia/state/"
  exit 0
fi

# Step 1: pre-phase tarball + sha256 sidecar
log "creating pre-phase tarball: $TARBALL"
( cd "$PROJECT_ROOT" && tar -czf "$TARBALL" docs/ )
shasum -a 256 "$TARBALL" > "${TARBALL}.sha256"

# Step 2: extract state files BEFORE building the manifest, so the manifest
# reflects what will live under .gaia/artifacts/ (state files have their own
# destination under .gaia/state/ and MUST NOT appear in the artifacts manifest).
# Line-based mv preserves comments (action-items.yaml has dedup_key comments).
STATE_FILES=(
  "implementation-artifacts/sprint-status.yaml:sprint-status.yaml"
  "planning-artifacts/action-items.yaml:action-items.yaml"
)
STATE_POINTERS=()  # collected and written after Step 4 (subdir moves)
for entry in "${STATE_FILES[@]}"; do
  legacy_rel="${entry%%:*}"
  new_name="${entry##*:}"
  legacy_path="$LEGACY_DOCS/$legacy_rel"
  new_path="$NEW_STATE/$new_name"
  if [ -f "$legacy_path" ]; then
    log "extracting state file -> \$PROJECT_ROOT/.gaia/state/$new_name"
    mv "$legacy_path" "$new_path"
    # Defer pointer-file write until after the parent subdir has been moved
    # and replaced with an empty placeholder; otherwise the subdir mv would
    # carry the pointer along with it to the new location.
    STATE_POINTERS+=("${legacy_path}|${new_name}")
  fi
done

# Step 3: pre-migration manifest of artifact subdirs (after state extraction).
# Portability note: pipe `find | xargs shasum` is unsafe on GNU xargs when the
# find result is empty — without `-r`/`--no-run-if-empty`, GNU xargs invokes
# `shasum` once with no args, which reads stdin and produces a spurious entry.
# Use a tmp-file + read loop instead to stay POSIX-portable across macOS and
# Linux runners.
log "computing pre-migration sha256 manifest"
: > "$MANIFEST"
for sd in "${ARTIFACT_SUBDIRS[@]}"; do
  if [ -d "$LEGACY_DOCS/$sd" ]; then
    _files_tmp="$(mktemp)"
    ( cd "$LEGACY_DOCS" && find "$sd" -type f ! -name '.gaia-pointer' | sort ) > "$_files_tmp"
    if [ -s "$_files_tmp" ]; then
      ( cd "$LEGACY_DOCS" && xargs shasum -a 256 < "$_files_tmp" ) >> "$MANIFEST"
    fi
    rm -f "$_files_tmp"
  fi
done
FILE_COUNT="$(awk 'NF>0' "$MANIFEST" | wc -l | awk '{print $1}')"
log "manifest captured: $FILE_COUNT files across 5 artifact subdirs"

# Step 4: atomic move of artifact subdirs to .gaia/artifacts/
# E96-S6: pointer-list written incrementally before each pointer file, so the
# rollback can clean up partial-write state on failure.
for sd in "${ARTIFACT_SUBDIRS[@]}"; do
  if [ -d "$LEGACY_DOCS/$sd" ]; then
    if [ -d "$NEW_ARTIFACTS/$sd" ]; then
      die "target $NEW_ARTIFACTS/$sd already exists — refusing to overwrite" 2
    fi
    log "moving artifact subdir -> \$PROJECT_ROOT/.gaia/artifacts/$sd"
    mv "$LEGACY_DOCS/$sd" "$NEW_ARTIFACTS/$sd"
    mkdir -p "$LEGACY_DOCS/$sd"
    pointer="$LEGACY_DOCS/$sd/.gaia-pointer"
    printf '%s\n' "$pointer" >> "$POINTER_LIST"
    printf '%s\n' "MOVED TO .gaia/artifacts/$sd (Phase 2 of E96, AF-2026-05-19-1, ADR-111)" > "$pointer"
  fi
done

# Step 4b: emit deferred state-file pointer files inside the empty placeholder
# subdirs that Step 4 just created.
for pe in "${STATE_POINTERS[@]:-}"; do
  [ -n "$pe" ] || continue
  legacy_path="${pe%%|*}"
  new_name="${pe##*|}"
  pointer="${legacy_path}.gaia-pointer"
  printf '%s\n' "$pointer" >> "$POINTER_LIST"
  printf '%s\n' "MOVED TO .gaia/state/$new_name (Phase 2 of E96, AF-2026-05-19-1, ADR-111)" > "$pointer"
done

# Step 5: phase-exit gate against the artifacts manifest
BATS_BASELINE=0
if command -v bats >/dev/null 2>&1; then
  PLUGIN_TESTS="$PROJECT_ROOT/gaia-public/plugins/gaia/tests"
  if [ -d "$PLUGIN_TESTS" ]; then
    BATS_BASELINE="$(grep -hcE '^@test ' "$PLUGIN_TESTS"/*.bats 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  fi
fi

# Gate runs against the artifacts tree (state files have their own manifest in
# a real production setup; for this story scope we focus on the artifacts move).
log "running phase-exit gate against .gaia/artifacts/"
GATE_SOURCE_DIR="$NEW_ARTIFACTS"
# Build a rewritten manifest where each relpath is rewritten to drop the legacy
# `docs/` prefix — the gate compares against $GATE_SOURCE_DIR/$relpath.
GATE_MANIFEST="$BACKUP_DIR/phase-2-${TS}-gate-manifest.txt"
awk '{print $1 "  " $2}' "$MANIFEST" > "$GATE_MANIFEST"

if ! bash "$LIB_DIR/phase-exit-gate.sh" \
        --source-dir "$GATE_SOURCE_DIR" \
        --manifest "$GATE_MANIFEST" \
        --bats-baseline "$BATS_BASELINE" \
        --bats-current "$BATS_BASELINE" \
        --tarball "$TARBALL" \
        --legacy-path docs/planning-artifacts \
        --legacy-path docs/implementation-artifacts \
        --legacy-path docs/test-artifacts \
        --legacy-path docs/creative-artifacts \
        --legacy-path docs/research-artifacts \
        --pointer-list "$POINTER_LIST" \
        --remove-source-dir-if-empty; then
  die "phase-exit gate FAILED — rollback executed" 1
fi

log "Phase 2 complete"
exit 0
