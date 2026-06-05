#!/usr/bin/env bash
# finalize.sh — gaia-sprint-close generic lifecycle hook.
#
# Mirrors the gaia-deploy / gaia-sprint-status pattern: writes the workflow
# checkpoint and emits a `workflow_complete` lifecycle event. The actual
# close action lives in the sibling script `close.sh` — this file is the
# generic plugin lifecycle hook the audit-v2-migration harness exercises.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-close/finalize.sh"
WORKFLOW_NAME="sprint-close"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

if [ -x "$CHECKPOINT" ]; then
  "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 2 >/dev/null 2>&1 || \
    log "checkpoint.sh write failed (non-fatal)"
fi

if [ -x "$LIFECYCLE_EVENT" ]; then
  "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1 || \
    log "lifecycle-event.sh emit failed (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
