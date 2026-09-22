#!/usr/bin/env bash
# checkpoint-reaper.sh — 30-day reaper for `_memory/checkpoints/` AND
# `_memory/meeting-sessions/`.
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

# Memory-tree segment, resolved through the shared paths helper rather than
# spelled out here, so a move of the tree is picked up automatically.
#
# gaia-paths.sh is a sibling in this directory, but it is NOT sourced at top
# level: the directories reaped below are composed from the caller's --root,
# and with PROJECT_ROOT unset the helper walks up from CWD and resolves some
# unrelated ancestor as the root — the reaper would then walk a tree the
# caller never named. Sourcing it in a subshell pinned to a sentinel root
# suppresses the walk-up; stripping that root back off leaves just the
# segment, which is composed onto --root below.
_gaia_memory_segment() {
  local lib _sentinel
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gaia-paths.sh"
  [ -r "$lib" ] || return 1
  _sentinel="/gaia-path-segment-probe"
  (
    # shellcheck disable=SC2030,SC2034  # the subshell is the point: the probe
    # root must not escape into the caller's environment, and the assignment is
    # read by the helper sourced on the next line, not by this script.
    PROJECT_ROOT="$_sentinel"
    _GAIA_PATHS_LOADED=""
    # shellcheck source=./gaia-paths.sh
    # shellcheck disable=SC1091  # resolved at runtime from this directory.
    . "$lib" >/dev/null 2>&1 || exit 1
    [ -n "${GAIA_MEMORY_DIR:-}" ] || exit 1
    printf '%s' "${GAIA_MEMORY_DIR#"$_GAIA_ROOT_CANON"/}"
  )
}

MEMORY_SEGMENT="$(_gaia_memory_segment || true)"
if [[ -z "$MEMORY_SEGMENT" ]]; then
  echo "checkpoint-reaper.sh: could not resolve the memory tree via the shared paths helper" >&2
  exit 3
fi

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

# Reap the canonical memory tree beneath the caller's --root. The prior code
# reaped only the legacy pre-consolidation paths. With the default tree these
# resolve to `<root>/.gaia/memory/checkpoints` and
# `<root>/.gaia/memory/meeting-sessions` — the segment comes from the shared
# paths helper so a tree move is picked up without editing these lines.
reap_dir "$ROOT/$MEMORY_SEGMENT/checkpoints"
reap_dir "$ROOT/$MEMORY_SEGMENT/meeting-sessions"

exit 0
