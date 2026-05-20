#!/usr/bin/env bash
# phase-exit-gate.sh — shared 3-criteria phase-exit gate for the .gaia/
# consolidation migration (E96-S1, ADR-111; consumed by E96-S2..S5).
#
# Verifies that a phase migration is safe to mark done:
#   1. bats baseline regression — current test count >= recorded baseline
#   2. per-file existence — every manifest row's file exists at the target
#   3. sha256 parity — every migrated file matches its pre-migration hash
#
# Criterion (2) was rewritten in E96-S6 (hotfix). The original gate ran
# `find <source-dir> -type f | wc -l` which falsely triggered rollback when
# the target directory was shared across phases (e.g. Phase 2 writes
# .gaia/state/sprint-status.yaml, then Phase 3 runs and `find .gaia/state`
# returns more files than the Phase 3 manifest records). The fix: iterate
# the manifest and verify each file exists; extra files at the target from
# prior phases are ignored.
#
# On any failure, the gate triggers automatic rollback via tar extraction
# of the pre-phase tarball. Rollback is per-file scoped: it deletes ONLY the
# files this phase's manifest recorded at their target paths, NOT the parent
# directory (so prior phases' files survive). Tarball-integrity (sha256
# sidecar) is verified BEFORE rollback; integrity failure refuses the
# rollback and exits with a CRITICAL halt.
#
# Usage:
#   phase-exit-gate.sh \
#     --source-dir <new path with migrated files> \
#     --manifest <pre-migration sha256 manifest> \
#     --bats-baseline <N> --bats-current <N> \
#     [--tarball <pre-phase tarball.tar.gz>] \
#     [--legacy-path <relpath>]            (repeatable; cleared pre-extract) \
#     [--pointer-list <file>]              (newline-separated absolute paths) \
#     [--remove-source-dir-if-empty]       (rmdir source-dir after per-file delete)
#
# Exit codes:
#   0 — all 3 criteria pass
#   1 — at least one criterion failed; rollback attempted
#   2 — tarball integrity check failed; rollback REFUSED (CRITICAL halt)
#
# References:
#   - FR-508 (phase-exit gate); SR-73 (pre-phase tarball + sha256 manifest);
#     TC-GLM-1 (bats coverage); NFR-075 (idempotency).
#   - E96-S6 (hotfix) — Defects A/B/C/D resolution.

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
LEGACY_PATHS=()
POINTER_LIST=""
REMOVE_SOURCE_DIR_IF_EMPTY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-dir)    SOURCE_DIR="$2"; shift 2 ;;
    --manifest)      MANIFEST="$2"; shift 2 ;;
    --bats-baseline) BATS_BASELINE="$2"; shift 2 ;;
    --bats-current)  BATS_CURRENT="$2"; shift 2 ;;
    --tarball)       TARBALL="$2"; shift 2 ;;
    --legacy-path)   LEGACY_PATHS+=("$2"); shift 2 ;;
    --pointer-list)  POINTER_LIST="$2"; shift 2 ;;
    --remove-source-dir-if-empty) REMOVE_SOURCE_DIR_IF_EMPTY=1; shift ;;
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
  shasum -a 256 "$1" | awk '{print $1}'
}

_extract_root() {
  # The tarball was built relative to the project root. From SOURCE_DIR like
  # "$PROJECT_ROOT/.gaia/state", walk up until we find the project root —
  # heuristically the directory that contains `.gaia-migrate-backup/`.
  local d="$SOURCE_DIR"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    d="$(dirname -- "$d")"
    if [ -d "$d/.gaia-migrate-backup" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  # Fallback: assume SOURCE_DIR = <root>/.gaia/<subdir>, so root = parent of parent.
  printf '%s' "$(dirname -- "$(dirname -- "$SOURCE_DIR")")"
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

  local extract_root
  extract_root="$(_extract_root)"

  # Step 1: per-file delete (E96-S6 Defect B.1 fix).
  # Iterate the manifest and remove only this phase's files at the target.
  # NEVER `rm -rf "$SOURCE_DIR"` — that destroys prior phases' contributions.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local rel_path full_path
    rel_path="$(printf '%s\n' "$line" | awk '{$1=""; sub(/^[ \t]+/, ""); print}')"
    rel_path="${rel_path#./}"
    full_path="$SOURCE_DIR/$rel_path"
    if [ -f "$full_path" ]; then
      rm -f "$full_path"
    fi
  done < "$MANIFEST"

  # Step 2: remove pointer-file orphans (E96-S6 Defect C fix).
  if [ -n "$POINTER_LIST" ] && [ -f "$POINTER_LIST" ]; then
    while IFS= read -r pointer_path; do
      [ -n "$pointer_path" ] || continue
      if [ -f "$pointer_path" ]; then
        rm -f "$pointer_path"
      fi
    done < "$POINTER_LIST"
  fi

  # Step 3: remove the source directory if empty (E96-S6 Defect D fix).
  # `find -empty -delete` only removes empty directories — non-empty ones
  # (from prior phases) are kept untouched.
  if [ "$REMOVE_SOURCE_DIR_IF_EMPTY" = "1" ]; then
    find "$SOURCE_DIR" -depth -type d -empty -delete 2>/dev/null || true
  fi

  # Step 4: legacy-path cleanup (E96-S6 Defect B.2 fix — parameterized).
  # Only remove paths the caller explicitly named.
  local lp
  for lp in "${LEGACY_PATHS[@]+"${LEGACY_PATHS[@]}"}"; do
    [ -n "$lp" ] || continue
    rm -rf "$extract_root/$lp"
  done

  # Step 5: extract the tarball to restore the pre-phase state.
  tar -xzf "$TARBALL" -C "$extract_root"

  printf '%s: rollback complete\n' "$SCRIPT_NAME" >&2
  exit 1
}

# ---------- Criterion 1: bats baseline ----------

if [ "$BATS_CURRENT" -lt "$BATS_BASELINE" ]; then
  _rollback "bats baseline regression: current=$BATS_CURRENT < baseline=$BATS_BASELINE"
fi

# ---------- Criterion 2 (rewritten in E96-S6): per-file existence ----------

EXISTS_COUNT=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  rec_path="$(printf '%s\n' "$line" | awk '{$1=""; sub(/^[ \t]+/, ""); print}')"
  rec_path="${rec_path#./}"
  full_path="$SOURCE_DIR/$rec_path"
  if [ ! -f "$full_path" ]; then
    _rollback "per-file existence: missing file $rec_path at $SOURCE_DIR"
  fi
  EXISTS_COUNT=$((EXISTS_COUNT+1))
done < "$MANIFEST"

# ---------- Criterion 3: sha256 parity ----------

while IFS= read -r line; do
  [ -n "$line" ] || continue
  rec_hash="$(printf '%s\n' "$line" | awk '{print $1}')"
  rec_path="$(printf '%s\n' "$line" | awk '{$1=""; sub(/^[ \t]+/, ""); print}')"
  rec_path="${rec_path#./}"
  full_path="$SOURCE_DIR/$rec_path"
  actual_hash="$(_shasum_of "$full_path")"
  if [ "$actual_hash" != "$rec_hash" ]; then
    _rollback "sha256 hash mismatch on $rec_path (recorded=$rec_hash actual=$actual_hash)"
  fi
done < "$MANIFEST"

printf '%s: PASS (bats=%s>=%s files=%s sha256=ok)\n' \
  "$SCRIPT_NAME" "$BATS_CURRENT" "$BATS_BASELINE" "$EXISTS_COUNT"
exit 0
