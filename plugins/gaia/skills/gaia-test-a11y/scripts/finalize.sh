#!/usr/bin/env bash
# finalize.sh — gaia-test-a11y skill lifecycle finalize.
#
# Standard lifecycle hook (parallel to gaia-test-perf/finalize.sh):
#   1. Write a checkpoint via checkpoint.sh
#   2. Emit a lifecycle event via lifecycle-event.sh
#
# Exit codes:
#   0 — finalize succeeded (checkpoint + event hooks are non-fatal)
#   1 — unexpected error
#
# POSIX discipline: bash 3.2 / macOS-compatible, set -euo pipefail, LC_ALL=C.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-a11y/finalize.sh"
WORKFLOW_NAME="test-a11y"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---------- 1. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 5 >/dev/null 2>&1; then
    log "checkpoint written for $WORKFLOW_NAME"
  else
    log "checkpoint.sh write failed for $WORKFLOW_NAME (non-fatal)"
  fi
else
  log "checkpoint.sh not found — skipping checkpoint write (non-fatal)"
fi

# ---------- 2. Emit lifecycle event ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    log "lifecycle event emitted for $WORKFLOW_NAME"
  else
    log "lifecycle-event.sh emit failed for $WORKFLOW_NAME (non-fatal)"
  fi
else
  log "lifecycle-event.sh not found — skipping event emission (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
