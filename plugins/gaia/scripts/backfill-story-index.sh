#!/usr/bin/env bash
# backfill-story-index.sh — back-fill missing per-epic story indexes.
#
# Scan every per-epic directory under {implementation_artifacts}/epic-*/ and
# invoke `transition-story-status.sh --reconcile-only` for each story file
# whose epic does not yet have a `story-index.yaml`. This covers the missing
# orchestrator hook the bare /gaia-create-story bulk-authoring path skipped —
# the result was 0 of 3 epics carrying the per-epic index even though the live
# yaml + per-story story.md files were all on disk.
#
# Idempotent: runs the transition only when story-index.yaml is absent for
# the epic. Safe to call from any orchestrator (e.g., /gaia-sprint-plan
# Step 0, /gaia-create-story Step 6) without checking first.
#
# Usage:
#   backfill-story-index.sh [--implementation-artifacts <path>]
#
# Exits 0 on success (zero or more epics back-filled), non-zero on any
# transition-script error.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="backfill-story-index.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Resolve IMPLEMENTATION_ARTIFACTS via the same precedence as the rest of the
# framework: explicit flag → env var → resolve-config.sh → .gaia/ canonical.
IMPL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --implementation-artifacts) IMPL="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '1,30p' "$0" >&2
      exit 0
      ;;
    *) printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 64 ;;
  esac
done

if [ -z "$IMPL" ]; then
  IMPL="${IMPLEMENTATION_ARTIFACTS:-}"
fi
if [ -z "$IMPL" ]; then
  _rc="${SCRIPT_DIR}/resolve-config.sh"
  if [ -x "$_rc" ]; then
    IMPL="$("$_rc" implementation_artifacts 2>/dev/null || printf '')"
  fi
fi
IMPL="${IMPL:-${PROJECT_ROOT:-$PWD}/.gaia/artifacts/implementation-artifacts}"

if [ ! -d "$IMPL" ]; then
  printf '%s: nothing to back-fill — implementation-artifacts dir is absent (%s)\n' "$SCRIPT_NAME" "$IMPL" >&2
  exit 0
fi

TRANSITION="$SCRIPT_DIR/transition-story-status.sh"
if [ ! -x "$TRANSITION" ]; then
  printf '%s: missing dependency: %s\n' "$SCRIPT_NAME" "$TRANSITION" >&2
  exit 1
fi

# For each epic-* dir, check whether story-index.yaml exists at the epic root
# (per-story layout) or under stories/ (legacy). When absent at the epic
# root and at least one story.md exists under the epic, walk every per-story
# story.md and reconcile its key.
walked=0
backfilled=0
shopt -s nullglob
for _epic_dir in "$IMPL"/epic-*; do
  [ -d "$_epic_dir" ] || continue
  walked=$((walked + 1))
  if [ -f "$_epic_dir/story-index.yaml" ] || [ -f "$_epic_dir/stories/story-index.yaml" ]; then
    continue
  fi
  # Find every per-story story.md (per-story layout). Bail if there are none.
  _any=0
  for _story_md in "$_epic_dir"/*/story.md; do
    [ -f "$_story_md" ] || continue
    _any=1
    # Story key is the directory name's `<EPIC-KEY>-S<N>` prefix.
    _story_dir_name="$(basename "$(dirname "$_story_md")")"
    _story_key="${_story_dir_name%%-*}"
    case "$_story_dir_name" in
      *-S[0-9]*) _story_key="$(printf '%s' "$_story_dir_name" | awk -F'-' '{printf "%s-%s", $1, $2}')" ;;
    esac
    if [ -z "$_story_key" ] || ! printf '%s' "$_story_key" | grep -Eq '^E[0-9]+-S[0-9]+$'; then
      printf '%s: skipped %s — could not parse story-key from dir name\n' "$SCRIPT_NAME" "$_story_dir_name" >&2
      continue
    fi
    if "$TRANSITION" "$_story_key" --reconcile-only >&2; then
      backfilled=$((backfilled + 1))
    else
      printf '%s: transition --reconcile-only failed for %s\n' "$SCRIPT_NAME" "$_story_key" >&2
    fi
  done
  if [ "$_any" -eq 0 ]; then
    printf '%s: epic dir %s has no story.md files — skipped\n' "$SCRIPT_NAME" "$_epic_dir" >&2
  fi
done

printf '%s: walked %d epic(s); reconciled %d story registration(s)\n' "$SCRIPT_NAME" "$walked" "$backfilled" >&2
exit 0
