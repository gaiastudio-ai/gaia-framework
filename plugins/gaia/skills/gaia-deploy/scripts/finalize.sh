#!/usr/bin/env bash
# finalize.sh — gaia-deploy lifecycle hook (E73-S5).
#
# Writes the workflow checkpoint and emits a `workflow_complete` lifecycle
# event for the deploy run. Mirrors the gaia-test-e2e finalize.sh pattern.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/finalize.sh"
WORKFLOW_NAME="deploy"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EMIT="$PLUGIN_SCRIPTS_DIR/lifecycle-emit.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

if [ -x "$CHECKPOINT" ]; then
  "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --state '{"phase":"complete"}' >/dev/null 2>&1 || \
    log "checkpoint.sh write failed (non-fatal)"
fi

if [ -x "$LIFECYCLE_EMIT" ]; then
  "$LIFECYCLE_EMIT" --event workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1 || \
    log "lifecycle-emit failed (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
