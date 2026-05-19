#!/usr/bin/env bash
# migrate-phase-3.sh — Phase 3 of the .gaia/ consolidation epic (E96, ADR-111).
# Moves orphan root-level state files under `.gaia/state/` and relocates the
# user-extension `custom/` tree under `.gaia/custom/`.
#
# Phase 3 contract (E96-S3):
#   1. Pre-phase tarball + sha256 sidecar at .gaia-migrate-backup/.
#   2. Per-file sha256 manifest captured pre-move.
#   3. Move root-level state files: .review-gate-ledger, .plugin-list.json,
#      .public-smoke.json, .session-console.log — each gets a pointer file.
#   4. Atomic move of custom/ tree to .gaia/custom/ preserving content.
#   5. Pointer file at legacy custom/ location.
#   6. Project-root grep gate (AC7): assert no GAIA-owned files at root
#      outside .gaia/.
#   7. 3-criteria phase-exit gate.
#   8. Idempotent re-run.
#
# Usage:
#   migrate-phase-3.sh [--project-root <path>] [--dry-run]

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="migrate-phase-3.sh"
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
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# *//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$PWD}"
fi
PROJECT_ROOT="$( cd "$PROJECT_ROOT" 2>/dev/null && pwd -P || true )"
[ -n "$PROJECT_ROOT" ] && [ -d "$PROJECT_ROOT" ] || die "invalid project root"

ROOT_STATE_FILES=(.review-gate-ledger .plugin-list.json .public-smoke.json .session-console.log)
NEW_STATE="$PROJECT_ROOT/.gaia/state"
NEW_CUSTOM="$PROJECT_ROOT/.gaia/custom"
BACKUP_DIR="$PROJECT_ROOT/.gaia-migrate-backup"

# Idempotency check: all relocated state files present at new location, and
# no still-non-pointer files at root.
is_already_migrated() {
  local f any_remaining=0
  for f in "${ROOT_STATE_FILES[@]}"; do
    if [ -f "$PROJECT_ROOT/$f" ] && [ ! -f "$PROJECT_ROOT/$f.gaia-pointer" ]; then
      any_remaining=1
    fi
  done
  # custom/ should be either absent or only a pointer-file
  if [ -d "$PROJECT_ROOT/custom" ]; then
    if [ ! -f "$PROJECT_ROOT/custom/.gaia-pointer" ]; then
      any_remaining=1
    fi
  fi
  [ "$any_remaining" = "0" ] && [ -d "$NEW_CUSTOM" -o ! -d "$PROJECT_ROOT/custom" ]
}

if is_already_migrated; then
  log "Phase 3 already complete — no-op"
  exit 0
fi

mkdir -p "$BACKUP_DIR" "$NEW_STATE" "$NEW_CUSTOM"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
TARBALL="$BACKUP_DIR/phase-3-${TS}.tar.gz"
MANIFEST="$BACKUP_DIR/phase-3-${TS}-manifest.txt"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY-RUN: would tarball root state files + custom/ -> $TARBALL"
  log "DRY-RUN: would move root state files -> \$PROJECT_ROOT/.gaia/state/"
  log "DRY-RUN: would relocate custom/ -> \$PROJECT_ROOT/.gaia/custom/"
  exit 0
fi

# Step 1: pre-phase tarball
log "creating pre-phase tarball: $TARBALL"
TAR_TARGETS=()
for f in "${ROOT_STATE_FILES[@]}"; do
  if [ -f "$PROJECT_ROOT/$f" ]; then
    TAR_TARGETS+=("$f")
  fi
done
if [ -d "$PROJECT_ROOT/custom" ]; then
  TAR_TARGETS+=(custom)
fi
if [ "${#TAR_TARGETS[@]}" -gt 0 ]; then
  ( cd "$PROJECT_ROOT" && tar -czf "$TARBALL" "${TAR_TARGETS[@]}" )
  shasum -a 256 "$TARBALL" > "${TARBALL}.sha256"
else
  log "no pre-migration files to tarball — clean start"
fi

# Step 2: manifest of files-to-be-moved (custom/ tree contents + root state files at their NEW location after move)
: > "$MANIFEST"
for f in "${ROOT_STATE_FILES[@]}"; do
  if [ -f "$PROJECT_ROOT/$f" ]; then
    ( cd "$PROJECT_ROOT" && shasum -a 256 "$f" ) >> "$MANIFEST"
  fi
done
if [ -d "$PROJECT_ROOT/custom" ]; then
  _files_tmp="$(mktemp)"
  ( cd "$PROJECT_ROOT" && find custom -type f ! -name '.gaia-pointer' | sort ) > "$_files_tmp"
  if [ -s "$_files_tmp" ]; then
    ( cd "$PROJECT_ROOT" && xargs shasum -a 256 < "$_files_tmp" ) >> "$MANIFEST"
  fi
  rm -f "$_files_tmp"
fi
FILE_COUNT="$(awk 'NF>0' "$MANIFEST" | wc -l | awk '{print $1}')"
log "manifest captured: $FILE_COUNT files"

# Step 3: move root state files to .gaia/state/
for f in "${ROOT_STATE_FILES[@]}"; do
  if [ -f "$PROJECT_ROOT/$f" ]; then
    log "moving root state file -> \$PROJECT_ROOT/.gaia/state/$f"
    mv "$PROJECT_ROOT/$f" "$NEW_STATE/$f"
    printf '%s\n' "MOVED TO .gaia/state/$f (Phase 3 of E96, AF-2026-05-19-1, ADR-111)" > "$PROJECT_ROOT/$f.gaia-pointer"
  fi
done

# Step 4: relocate custom/ to .gaia/custom/
if [ -d "$PROJECT_ROOT/custom" ]; then
  log "relocating custom/ -> \$PROJECT_ROOT/.gaia/custom/"
  # Move contents preserving structure. The destination already exists from
  # the mkdir -p above, so use a sub-tree merge.
  if [ -z "$(ls -A "$NEW_CUSTOM" 2>/dev/null)" ]; then
    rmdir "$NEW_CUSTOM"
    mv "$PROJECT_ROOT/custom" "$NEW_CUSTOM"
  else
    die "target $NEW_CUSTOM is non-empty — refusing to merge" 2
  fi
  mkdir -p "$PROJECT_ROOT/custom"
  printf '%s\n' "MOVED TO .gaia/custom/ (Phase 3 of E96, AF-2026-05-19-1, ADR-111)" > "$PROJECT_ROOT/custom/.gaia-pointer"
fi

# Step 5: project-root grep gate (AC7)
# Any of the canonical root state files still present and not-a-pointer is a failure.
ROOT_VIOLATIONS=()
for f in "${ROOT_STATE_FILES[@]}"; do
  if [ -f "$PROJECT_ROOT/$f" ]; then
    ROOT_VIOLATIONS+=("$f")
  fi
done
if [ "${#ROOT_VIOLATIONS[@]}" -gt 0 ]; then
  log "project-root grep gate FAILED — still at root: ${ROOT_VIOLATIONS[*]}"
  exit 1
fi

# Step 6: phase-exit gate against the manifest (.gaia/state/ + .gaia/custom/ merged view)
# We build a unified source dir lookup: state files live in .gaia/state/, custom
# files live in .gaia/custom/. To reuse phase-exit-gate.sh (which expects a single
# source dir), we run two gate passes — one per destination — using filtered
# manifests.

run_partial_gate() {
  local src_dir="$1" manifest_filter="$2" manifest_part
  manifest_part="$(mktemp)"
  # The manifest stores relpaths like `.review-gate-ledger` or `custom/foo`.
  # The filter selects only the rows that match the destination naming.
  grep -E "$manifest_filter" "$MANIFEST" > "$manifest_part" || true
  if [ ! -s "$manifest_part" ]; then
    rm -f "$manifest_part"
    return 0
  fi
  # Rewrite paths so the gate's "${src_dir}/${rel}" lookup matches the
  # destination layout.
  local rewritten="$(mktemp)"
  case "$src_dir" in
    *"/.gaia/state")
      # Manifest rows look like: "<hash>  .review-gate-ledger"
      # At source_dir we want the same basename — no rewrite needed.
      cp "$manifest_part" "$rewritten" ;;
    *"/.gaia/custom")
      # Manifest rows look like: "<hash>  custom/<rel>"
      # Strip the leading "custom/" so the gate finds it under .gaia/custom/<rel>.
      sed 's|  custom/|  |' "$manifest_part" > "$rewritten" ;;
    *)
      cp "$manifest_part" "$rewritten" ;;
  esac
  rm -f "$manifest_part"
  if ! bash "$LIB_DIR/phase-exit-gate.sh" \
        --source-dir "$src_dir" \
        --manifest "$rewritten" \
        --bats-baseline 0 --bats-current 0 \
        --tarball "$TARBALL"; then
    rm -f "$rewritten"
    return 1
  fi
  rm -f "$rewritten"
  return 0
}

# Skip the gate when there's nothing migrated.
if [ "$FILE_COUNT" -gt 0 ]; then
  STATE_PATTERN="$(printf '%s\n' "${ROOT_STATE_FILES[@]}" | sed 's/[][\.*^$()|]/\\&/g' | paste -sd'|' -)"
  if [ -n "$STATE_PATTERN" ]; then
    if ! run_partial_gate "$NEW_STATE" "  (${STATE_PATTERN})$"; then
      die "phase-exit gate FAILED on .gaia/state/ — rollback executed" 1
    fi
  fi
  if [ -d "$NEW_CUSTOM" ]; then
    if ! run_partial_gate "$NEW_CUSTOM" "  custom/"; then
      die "phase-exit gate FAILED on .gaia/custom/ — rollback executed" 1
    fi
  fi
fi

log "Phase 3 complete"
exit 0
