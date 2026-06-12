#!/usr/bin/env bash
# finalize.sh — gaia-refresh-ground-truth skill finalize
#
# Follows the shared finalize.sh pattern.
#
# Responsibilities:
#   1. Write a checkpoint via the shared checkpoint.sh foundation script
#   2. Emit a lifecycle event via lifecycle-event.sh
#
# Exit codes:
#   0 — finalize succeeded
#   1 — checkpoint write or lifecycle event emission failed
#
# Marker contract:
#   The `.ground-truth-stale` marker is cleared EXCLUSIVELY here, on the
#   successful-refresh path. This step runs AFTER the required checkpoint and
#   lifecycle-event steps (both of which `die` on failure), so a FAILED refresh
#   never reaches the clear and never false-clears the marker.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-refresh-ground-truth/finalize.sh"
WORKFLOW_NAME="gaia-refresh-ground-truth"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 10 >/dev/null 2>&1; then
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

# ---------- 3. Clear the .ground-truth-stale marker (success path only) ----------
# Reached only after the required checkpoint + lifecycle-event steps succeeded,
# i.e. a successful refresh. The marker path is resolved through the loader's
# idiom (MEMORY_PATH override → CLAUDE_PROJECT_ROOT/.gaia/memory default), never
# a hardcoded relative literal. `rm -f` is idempotent — an absent marker is a
# no-op.
marker="${MEMORY_PATH:-${CLAUDE_PROJECT_ROOT:-.}/.gaia/memory}/.ground-truth-stale"
rm -f "$marker"
log "cleared .ground-truth-stale marker (successful refresh)"

log "finalize complete for $WORKFLOW_NAME"
exit 0
