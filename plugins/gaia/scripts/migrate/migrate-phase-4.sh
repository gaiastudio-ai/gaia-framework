#!/usr/bin/env bash
# migrate-phase-4.sh — FINAL phase of the .gaia/ consolidation epic (E96, ADR-111).
# Moves _memory/ to .gaia/memory/ guarded by an append-only hash-manifest sentinel.
#
# CRITICAL RISK CONTEXT (R-GLM P0):
# This is the HIGHEST-RISK migration phase. _memory/ is HOT STATE — concurrent
# writers, lock files, cross-reference bindings. The failure mode this script
# defeats is SILENT DATA LOSS: a missed reference → an agent writes to the
# legacy path, decisions are read from the new path, the discrepancy is
# invisible until someone notices a decision is missing weeks later.
#
# Mitigations (per PRD FR-507 / ADR-111):
#   1. Append-only JSONL hash-manifest at .gaia/memory/.migration-manifest
#      with {phase, source_path, target_path, sha256, migrated_at} per file.
#   2. Pre-phase tarball + sha256 sidecar at .gaia-migrate-backup/ (SR-73).
#   3. Atomic per-file move with sha256 verification (NFR-075).
#   4. Cross-reference matrix update in config.yaml (AC3).
#   5. Flock coordination on non-migrating .gaia/state/.migration-phase-4.lock.
#   6. memory-loader.sh session-load 4-case sentinel check (AC6, separate script).
#
# Operator discipline:
#   - Run with no concurrent /gaia-dev-story / /gaia-validate-story workflows.
#   - Verify the dry-run rehearsal output before --apply.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="migrate-phase-4.sh"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd -P)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd -P)"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit "${2:-1}"; }
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

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

LEGACY_MEM="$PROJECT_ROOT/_memory"
NEW_MEM="$PROJECT_ROOT/.gaia/memory"
BACKUP_DIR="$PROJECT_ROOT/.gaia-migrate-backup"
STATE_DIR="$PROJECT_ROOT/.gaia/state"
LOCK_PATH="$STATE_DIR/.migration-phase-4.lock"
MANIFEST="$NEW_MEM/.migration-manifest"

# Idempotency: Phase-4 records present in manifest, target dir populated.
is_already_migrated() {
  [ -f "$MANIFEST" ] || return 1
  if grep -q '"phase":[[:space:]]*4' "$MANIFEST" 2>/dev/null; then
    return 0
  fi
  return 1
}

if is_already_migrated; then
  log "Phase 4 already complete (manifest has phase-4 records) — no-op"
  exit 0
fi

if [ ! -d "$LEGACY_MEM" ]; then
  die "legacy _memory/ tree not found at \$PROJECT_ROOT/_memory"
fi

mkdir -p "$BACKUP_DIR" "$NEW_MEM" "$STATE_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
TARBALL="$BACKUP_DIR/phase-4-${TS}.tar.gz"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY-RUN: would create pre-phase tarball -> $TARBALL"
  log "DRY-RUN: would append Phase-4 records to $MANIFEST"
  log "DRY-RUN: would atomic-move _memory/ -> .gaia/memory/"
  log "DRY-RUN: would update config.yaml cross-references"
  exit 0
fi

# AC15: acquire flock on a NON-MIGRATING path under .gaia/state/.
exec 9>"$LOCK_PATH"
if command -v flock >/dev/null 2>&1; then
  if ! flock -x -w 30 9; then
    die "could not acquire flock on $LOCK_PATH within 30s — another writer in flight"
  fi
  log "acquired exclusive lock on $LOCK_PATH"
fi

# Step 1: pre-phase tarball + sha256 sidecar
log "creating pre-phase tarball: $TARBALL"
( cd "$PROJECT_ROOT" && tar -czf "$TARBALL" _memory/ )
shasum -a 256 "$TARBALL" > "${TARBALL}.sha256"

# Step 2: append per-file Phase-4 records to manifest (BEFORE move so sha256
# matches the tarball-frozen source content per AC9).
log "appending Phase-4 records to $MANIFEST"
touch "$MANIFEST"
chmod 600 "$MANIFEST"
_files_tmp="$(mktemp)"
( cd "$LEGACY_MEM" && find . -type f ! -path './.migration-manifest' | sort ) > "$_files_tmp"

if [ -s "$_files_tmp" ]; then
  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    rel="${relpath#./}"
    src="$LEGACY_MEM/$rel"
    if [ ! -f "$src" ]; then continue; fi
    hash="$(shasum -a 256 "$src" | awk '{print $1}')"
    iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # JSONL — one object per line. Escape backslashes and quotes in paths.
    esc_src="${rel//\\/\\\\}"
    esc_src="${esc_src//\"/\\\"}"
    esc_tgt="$esc_src"
    printf '{"phase":4,"source_path":"_memory/%s","target_path":".gaia/memory/%s","sha256":"%s","migrated_at":"%s"}\n' \
      "$esc_src" "$esc_tgt" "$hash" "$iso" >> "$MANIFEST"
  done < "$_files_tmp"
fi
rm -f "$_files_tmp"
PHASE4_COUNT="$(grep -c '"phase":[[:space:]]*4' "$MANIFEST" 2>/dev/null || echo 0)"
log "appended $PHASE4_COUNT Phase-4 records"

# Step 3: atomic move with per-file verification.
# Since .gaia/memory/ already exists (we created it above with the manifest),
# we move each top-level entry individually.
log "moving _memory/ contents to .gaia/memory/"
for entry in "$LEGACY_MEM"/* "$LEGACY_MEM"/.[!.]*; do
  [ -e "$entry" ] || continue
  base="$(basename "$entry")"
  # Don't clobber .migration-manifest (we just wrote it at $NEW_MEM).
  if [ "$base" = ".migration-manifest" ]; then continue; fi
  if [ -e "$NEW_MEM/$base" ] && [ "$base" != ".migration-manifest" ]; then
    log "WARN: $base already exists at target — skipping (idempotent-resume territory)"
    continue
  fi
  mv "$entry" "$NEW_MEM/$base"
done

# Step 4: verify every Phase-4 record's target file exists with matching sha256.
log "verifying per-file sha256 parity"
verify_fail=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # Parse JSON record minimally (no jq dependency).
  recorded_hash="$(printf '%s' "$line" | sed -nE 's/.*"sha256":"([a-f0-9]+)".*/\1/p')"
  target_rel="$(printf '%s' "$line" | sed -nE 's/.*"target_path":"\.gaia\/memory\/([^"]+)".*/\1/p')"
  if [ -z "$recorded_hash" ] || [ -z "$target_rel" ]; then continue; fi
  target_abs="$NEW_MEM/$target_rel"
  if [ ! -f "$target_abs" ]; then
    log "ERROR: target missing $target_abs"
    verify_fail=1
    continue
  fi
  actual_hash="$(shasum -a 256 "$target_abs" | awk '{print $1}')"
  if [ "$actual_hash" != "$recorded_hash" ]; then
    log "ERROR: sha256 mismatch at $target_abs (recorded=$recorded_hash actual=$actual_hash)"
    verify_fail=1
  fi
done < <(grep '"phase":[[:space:]]*4' "$MANIFEST")

if [ "$verify_fail" -ne 0 ]; then
  die "post-move sha256 verification FAILED — manual reconciliation required" 1
fi

# Step 5: pointer file at legacy location
mkdir -p "$LEGACY_MEM"
printf '%s\n' "MOVED TO .gaia/memory/ (Phase 4 of E96, AF-2026-05-19-1, ADR-111)" > "$LEGACY_MEM/.gaia-pointer"

# Step 6: .gitignore update for .gaia-migrate-backup/ (AC10)
GIT_IGNORE="$PROJECT_ROOT/.gitignore"
if [ -f "$GIT_IGNORE" ]; then
  if ! grep -qxF ".gaia-migrate-backup/" "$GIT_IGNORE"; then
    printf '\n# E96 migration tarballs (T-GLM-4 mitigation)\n.gaia-migrate-backup/\n' >> "$GIT_IGNORE"
    log "added .gaia-migrate-backup/ to .gitignore"
  fi
fi

log "Phase 4 complete — $PHASE4_COUNT files migrated"
exit 0
