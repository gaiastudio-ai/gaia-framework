#!/usr/bin/env bash
# load-story.sh — story lifecycle wrapper
#
# Thin wrapper around the shared sprint-state.sh foundation script.
# Retrieves the current status of a story by key.
#
# Usage:
#   load-story.sh <story_key>
#
# Exit codes:
#   0 — story status retrieved successfully (printed to stdout)
#   1 — story not found or sprint-state.sh failure

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-check-dod/load-story.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

SPRINT_STATE="$PLUGIN_SCRIPTS_DIR/sprint-state.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ $# -lt 1 ]; then
  die "usage: load-story.sh <story_key>"
fi

STORY_KEY="$1"

if [ ! -x "$SPRINT_STATE" ]; then
  die "sprint-state.sh not found or not executable at $SPRINT_STATE"
fi

"$SPRINT_STATE" get --story "$STORY_KEY"
