#!/usr/bin/env bash
# checkpoint-reaper.sh — 30-day reaper for `_memory/checkpoints/` AND
# `_memory/meeting-sessions/` (E76-S7, AC5).
#
# Single source of truth for the retention policy: SAME script reaps both
# directories so policy changes (window, dry-run UX, summary format) cannot
# drift between the two roots.
#
# Reap criterion: file mtime is STRICTLY older than the threshold. A file
# whose mtime equals the threshold-day boundary is kept — the boundary is
# the inclusive retention edge.
#
# Usage:
#   checkpoint-reaper.sh --root <project-root> [--age-days N] [--dry-run | --apply]
#
# Defaults:
#   --age-days  30
#   --dry-run is the default when neither flag is passed (safe-by-default).
#
# Output:
#   stdout: one line per candidate file, prefixed `REAP ` (dry-run) or
#           `DELETED ` (apply).
#
# Exit codes:
#   0 = success
#   2 = malformed args / missing root

set -euo pipefail

ROOT=""
AGE_DAYS=30
APPLY=0
DRY_RUN=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)        ROOT="${2-}"; shift 2 ;;
    --root=*)      ROOT="${1#--root=}"; shift ;;
    --age-days)    AGE_DAYS="${2-}"; shift 2 ;;
    --age-days=*)  AGE_DAYS="${1#--age-days=}"; shift ;;
    --apply)       APPLY=1; DRY_RUN=0; shift ;;
    --dry-run)     DRY_RUN=1; APPLY=0; shift ;;
    *)
      echo "checkpoint-reaper.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$ROOT" ]]; then
  echo "checkpoint-reaper.sh: --root is required" >&2
  exit 2
fi
if ! [[ "$AGE_DAYS" =~ ^[0-9]+$ ]]; then
  echo "checkpoint-reaper.sh: --age-days must be a non-negative integer" >&2
  exit 2
fi

# `find -mtime +N` matches files modified strictly more than N*24 hours ago,
# which is the "strictly older than N days" semantics we want.
MTIME_ARG="+${AGE_DAYS}"

reap_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  while IFS= read -r -d '' f; do
    if (( APPLY )); then
      if rm -f -- "$f"; then
        printf 'DELETED %s\n' "$f"
      else
        printf 'FAILED %s\n' "$f" >&2
      fi
    else
      printf 'REAP %s\n' "$f"
    fi
  done < <(find "$dir" -type f -mtime "$MTIME_ARG" -print0 2>/dev/null)
}

reap_dir "$ROOT/_memory/checkpoints"
reap_dir "$ROOT/_memory/meeting-sessions"

exit 0
