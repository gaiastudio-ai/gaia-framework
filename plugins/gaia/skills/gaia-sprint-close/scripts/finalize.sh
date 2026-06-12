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

# Ground-truth staleness BEST-EFFORT pass — before the lifecycle-event emit.
# NON-BLOCKING: on STALE or evaluation failure the shared gate WARNS to stderr
# and returns 0 (NFR fail-safe — never fail the close ceremony). Trapped so a
# helper error cannot abort the close.
GT_GATE_LIB="$PLUGIN_SCRIPTS_DIR/lib/ground-truth-gate.sh"
if [ -r "$GT_GATE_LIB" ]; then
  # shellcheck source=/dev/null
  . "$GT_GATE_LIB"
  gt_gate_best_effort "sprint-close" || true
fi

# Brain reindex BEST-EFFORT pass — before the lifecycle-event emit, mirroring the
# ground-truth-staleness placement above. NON-BLOCKING: the sprint's primary
# outcome must never be blocked by a knowledge-index rebuild, so a reindex
# failure WARNS to stderr and the close CONTINUES. The resolved binary is
# overridable via GAIA_BRAIN_REINDEX_BIN for testability.
BRAIN_REINDEX="${GAIA_BRAIN_REINDEX_BIN:-$PLUGIN_SCRIPTS_DIR/brain/gaia-brain-reindex.sh}"
if [ -x "$BRAIN_REINDEX" ]; then
  "$BRAIN_REINDEX" >/dev/null 2>&1 || log "brain reindex failed (non-fatal)"
fi

if [ -x "$LIFECYCLE_EVENT" ]; then
  "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1 || \
    log "lifecycle-event.sh emit failed (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
