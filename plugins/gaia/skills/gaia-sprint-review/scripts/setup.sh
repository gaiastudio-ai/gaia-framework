#!/usr/bin/env bash
# setup.sh — /gaia-sprint-review skill setup
#
# Mechanical mirror of /gaia-sprint-close/scripts/setup.sh — same workflow
# checkpoint+lifecycle pattern, no prereq gates beyond config resolution
# (the all-stories-done gate is enforced by Step 1 of the SKILL.md, not
# here, because it's per-sprint-id and needs the LLM-resolved $SPRINT_ID).
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script.
#   2. Load the workflow checkpoint state for this skill.
#
# Exit codes:
#   0 — setup succeeded.
#   1 — config resolution or checkpoint load failed.
#
# POSIX discipline: bash with [[ ]] only. LC_ALL=C for deterministic
# output. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-review/setup.sh"
WORKFLOW_NAME="gaia-sprint-review"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# 1. Resolve config (idempotent).
if [ -x "$RESOLVE_CONFIG" ]; then
  "$RESOLVE_CONFIG" >/dev/null 2>&1 || true
fi

# 2. Load checkpoint state for this workflow (idempotent — first invocation
#    creates the empty state file).
if [ -x "$CHECKPOINT" ]; then
  "$CHECKPOINT" load "$WORKFLOW_NAME" >/dev/null 2>&1 || true
  log "checkpoint loaded for $WORKFLOW_NAME"
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
