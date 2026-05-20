#!/usr/bin/env bash
# checkpoint-archive.sh — gaia-quick-dev checkpoint archival (E28-S117)
#
# Moves _memory/checkpoints/quick-dev-{spec_name}.yaml to
# _memory/checkpoints/completed/ preserving the original filename.
# Deterministic per ADR-042 — no LLM involvement.
#
# Usage:
#   checkpoint-archive.sh <spec_name>
#
# Exit codes:
#   0 — archived successfully
#   1 — missing checkpoint or permission error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-quick-dev/checkpoint-archive.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ $# -lt 1 ]; then
  die "usage: checkpoint-archive.sh <spec_name>"
fi

SPEC_NAME="$1"
WORK_DIR="${PROJECT_PATH:-$PWD}"
# E96-S7 partial-4c: smart-fallback
if [ -n "${CHECKPOINT_PATH:-}" ]; then
  CHECKPOINT_DIR="$CHECKPOINT_PATH"
elif [ -d "$WORK_DIR/.gaia/memory/checkpoints" ]; then
  CHECKPOINT_DIR="$WORK_DIR/.gaia/memory/checkpoints"
else
  CHECKPOINT_DIR="$WORK_DIR/_memory/checkpoints"
fi
ACTIVE="$CHECKPOINT_DIR/quick-dev-${SPEC_NAME}.yaml"
ARCHIVE_DIR="$CHECKPOINT_DIR/completed"
ARCHIVED="$ARCHIVE_DIR/quick-dev-${SPEC_NAME}.yaml"

if [ ! -f "$ACTIVE" ]; then
  die "no active checkpoint at $ACTIVE"
fi

mkdir -p "$ARCHIVE_DIR" || die "cannot create archive dir: $ARCHIVE_DIR"

if ! mv "$ACTIVE" "$ARCHIVED"; then
  die "failed to move $ACTIVE -> $ARCHIVED"
fi

log "archived $ACTIVE -> $ARCHIVED"
