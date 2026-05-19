#!/usr/bin/env bash
# phase-exit-gate.sh — shared 3-criteria phase-exit gate for the .gaia/
# consolidation migration (E96-S1, ADR-111; consumed by E96-S2..S4).
#
# Verifies that a phase migration is safe to mark done:
#   1. bats baseline regression — current test count >= recorded baseline
#   2. find-count parity — files at new location match the migration manifest
#   3. sha256 parity — every migrated file matches its pre-migration hash
#
# On any failure, the gate triggers automatic rollback via tar extraction
# of the pre-phase tarball, then exits non-zero with the failed criterion(s)
# named. Tarball-integrity (sha256 sidecar) is verified BEFORE rollback;
# integrity failure refuses the rollback and exits with a CRITICAL halt.
#
# Usage:
#   phase-exit-gate.sh \
#     --source-dir <new path with migrated files> \
#     --manifest <pre-migration sha256 manifest> \
#     --bats-baseline <N> --bats-current <N> \
#     [--tarball <pre-phase tarball.tar.gz>]
#
# Exit codes:
#   0 — all 3 criteria pass
#   1 — at least one criterion failed; rollback attempted
#   2 — tarball integrity check failed; rollback REFUSED (CRITICAL halt)
#
# References:
#   - FR-508 (phase-exit gate); SR-73 (pre-phase tarball + sha256 manifest);
#     TC-GLM-1 (bats coverage); NFR-075 (idempotency).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="phase-exit-gate.sh"

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  exit "${2:-1}"
}

# ---------- Argument parsing ----------

SOURCE_DIR=""
MANIFEST=""
BATS_BASELINE=""
BATS_CURRENT=""
TARBALL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-dir)    SOURCE_DIR="$2"; shift 2 ;;
    --manifest)      MANIFEST="$2"; shift 2 ;;
    --bats-baseline) BATS_BASELINE="$2"; shift 2 ;;
    --bats-current)  BATS_CURRENT="$2"; shift 2 ;;
    --tarball)       TARBALL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$SOURCE_DIR" ]    || die "--source-dir required"
[ -n "$MANIFEST" ]      || die "--manifest required"
[ -n "$BATS_BASELINE" ] || die "--bats-baseline required"
[ -n "$BATS_CURRENT" ]  || die "--bats-current required"
[ -d "$SOURCE_DIR" ]    || die "source dir not found: $SOURCE_DIR"
[ -f "$MANIFEST" ]      || die "manifest not found: $MANIFEST"

# ---------- Helpers ----------

_shasum_of() {
  # POSIX-portable per-file sha256.
  shasum -a 256 "$1" | awk '{print $1}'
}

_rollback() {
  local reason="$1"
  printf '%s: FAIL (%s) — attempting rollback\n' "$SCRIPT_NAME" "$reason" >&2
  if [ -z "$TARBALL" ]; then
    printf '%s: rollback skipped — no --tarball supplied\n' "$SCRIPT_NAME" >&2
    exit 1
  fi
  if [ ! -f "$TARBALL" ]; then
    printf '%s: CRITICAL: tarball missing at %s\n' "$SCRIPT_NAME" "$TARBALL" >&2
    exit 2
  fi
  # Verify tarball integrity via .sha256 sidecar (SR-73).
  local sidecar="${TARBALL}.sha256"
  if [ -f "$sidecar" ]; then
    local recorded actual
    recorded="$(awk '{print $1}' "$sidecar")"
    actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    if [ "$recorded" != "$actual" ]; then
      printf '%s: CRITICAL: tarball sha256 mismatch (recorded=%s actual=%s) — rollback REFUSED\n' \
        "$SCRIPT_NAME" "$recorded" "$actual" >&2
      exit 2
    fi
  fi
  # Remove the half-migrated tree and restore from tarball.
  local target_parent
  target_parent="$(dirname -- "$SOURCE_DIR")"
  rm -rf "$SOURCE_DIR"
  # Tarball was built relative to the project root (paths like "config/...").
  # Extract to the directory containing the legacy `config/` location.
  local extract_root
  extract_root="$(dirname -- "$target_parent")"
  # If source-dir is .gaia/config, legacy lives at $extract_root/config.
  # Clean any pointer-file remnants at the legacy path first.
  rm -rf "$extract_root/config"
  tar -xzf "$TARBALL" -C "$extract_root"
  printf '%s: rollback complete\n' "$SCRIPT_NAME" >&2
  exit 1
}

# ---------- Criterion 1: bats baseline ----------

if [ "$BATS_CURRENT" -lt "$BATS_BASELINE" ]; then
  _rollback "bats baseline regression: current=$BATS_CURRENT < baseline=$BATS_BASELINE"
fi

# ---------- Criterion 2: find-count parity ----------

MANIFEST_COUNT="$(awk 'NF>0' "$MANIFEST" | wc -l | awk '{print $1}')"
ACTUAL_COUNT="$(find "$SOURCE_DIR" -type f | wc -l | awk '{print $1}')"

if [ "$ACTUAL_COUNT" != "$MANIFEST_COUNT" ]; then
  _rollback "file count mismatch (find-count): manifest=$MANIFEST_COUNT actual=$ACTUAL_COUNT"
fi

# ---------- Criterion 3: sha256 parity ----------

# Manifest format: "<hash>  <relpath>" (shasum default).
# Verify each file at SOURCE_DIR/<relpath> hashes to <hash>.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  rec_hash="$(printf '%s\n' "$line" | awk '{print $1}')"
  rec_path="$(printf '%s\n' "$line" | awk '{$1=""; sub(/^[ \t]+/, ""); print}')"
  # Strip leading "./" produced by `find .`
  rec_path="${rec_path#./}"
  full_path="$SOURCE_DIR/$rec_path"
  if [ ! -f "$full_path" ]; then
    _rollback "sha256 check: missing file $rec_path"
  fi
  actual_hash="$(_shasum_of "$full_path")"
  if [ "$actual_hash" != "$rec_hash" ]; then
    _rollback "sha256 hash mismatch on $rec_path (recorded=$rec_hash actual=$actual_hash)"
  fi
done < "$MANIFEST"

printf '%s: PASS (bats=%s>=%s files=%s sha256=ok)\n' \
  "$SCRIPT_NAME" "$BATS_CURRENT" "$BATS_BASELINE" "$ACTUAL_COUNT"
exit 0
