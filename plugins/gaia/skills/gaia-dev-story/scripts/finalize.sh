#!/usr/bin/env bash
# finalize.sh — gaia-dev-story skill finalize
#
# Mechanical copy of the reference implementation.
# Only WORKFLOW_NAME and SCRIPT_NAME differ.
#
# Responsibilities:
#   1. Write a checkpoint via the shared checkpoint.sh foundation script
#   2. Emit a lifecycle event via lifecycle-event.sh
#
# Exit codes:
#   0 — finalize succeeded
#   1 — checkpoint write or lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/finalize.sh"
WORKFLOW_NAME="gaia-dev-story"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"
VERIFY_PUSH="$PLUGIN_SCRIPTS_DIR/verify-push.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Verify push ----------
# Assert the feature branch is published on origin BEFORE we write the
# checkpoint or emit the lifecycle event. A silent push failure must not be
# allowed to leave the local branch unpublished while finalize claims success.
if [ -x "$VERIFY_PUSH" ]; then
  if ! "$VERIFY_PUSH"; then
    die "push verification failed — refusing to finalize $WORKFLOW_NAME (see verify-push.sh output above)"
  fi
  log "push verification passed for $WORKFLOW_NAME"
else
  log "verify-push.sh not found at $VERIFY_PUSH — skipping push verification (non-fatal)"
fi

# ---------- 1. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 14 >/dev/null 2>&1; then
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
