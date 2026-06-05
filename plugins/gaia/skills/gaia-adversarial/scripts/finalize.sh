#!/usr/bin/env bash
# finalize.sh — gaia-adversarial skill finalize
#
# This skill finalize provides a wire-in point for the auto-save helper.
# The skill body itself does not write artifacts that need post_complete
# checklist enforcement, so this finalize stays minimal: emit observability
# (checkpoint, lifecycle event) and call the auto-save helper.
#
# Exit codes:
#   0  always (auto-save failures are non-blocking)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-adversarial/finalize.sh"
WORKFLOW_NAME="adversarial-review"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---------- 1. Write checkpoint (observability) ----------
if [ -x "$CHECKPOINT" ]; then
  "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step end >/dev/null 2>&1 || \
    log "checkpoint.sh write failed for $WORKFLOW_NAME (non-fatal)"
fi

# ---------- 2. Emit lifecycle event (observability) ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1 || \
    log "lifecycle-event.sh emit failed for $WORKFLOW_NAME (non-fatal)"
fi

# ---------- 3. Auto-save session memory ----------
# Phase 1-3 skills auto-save a session summary to the agent sidecar via
# the shared lib helper. Phase 4 skills (e.g. /gaia-dev-story) short-
# circuit to a no-op so the interactive prompt is preserved. Failure is
# non-blocking — the auto-save helper itself logs warnings to stderr but
# never affects this script's exit code. SKILL_NAME is resolved from the
# parent directory name so the wire-in is identical across Phase 1-3
# finalize.sh files.
AUTOSAVE_LIB="$PLUGIN_SCRIPTS_DIR/lib/auto-save-memory.sh"
SKILL_NAME="$(basename "$(cd "$SCRIPT_DIR/.." && pwd)")"
if [ -f "$AUTOSAVE_LIB" ]; then
  # shellcheck disable=SC1090
  . "$AUTOSAVE_LIB"
  if ! _auto_save_memory "$SKILL_NAME" "${ARTIFACT:-}"; then
    AUTOSAVE_RC=$?
    if [ "$AUTOSAVE_RC" -eq 64 ]; then
      log "auto-save aborted: cannot resolve agent sidecar for skill $SKILL_NAME"
    fi
  fi
else
  log "auto-save-memory.sh not found at $AUTOSAVE_LIB — skipping auto-save (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
