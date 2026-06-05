#!/usr/bin/env bash
# finalize.sh — change-request redirect skill finalize
#
# Mechanical copy of the reference implementation. Only
# WORKFLOW_NAME and SCRIPT_NAME differ.
#
# Responsibilities:
#   1. Write a checkpoint via the shared checkpoint.sh foundation script
#   2. Emit a lifecycle event via lifecycle-event.sh for the tailing sync agent
#
# Exit codes:
#   0 — finalize succeeded
#   1 — checkpoint write or lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-change-request/finalize.sh"
WORKFLOW_NAME="change-request"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 3 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

# ---------- 2. Emit lifecycle event ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    die "lifecycle-event.sh emit failed for $WORKFLOW_NAME"
  fi
  log "lifecycle event emitted for $WORKFLOW_NAME"
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event emission (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
