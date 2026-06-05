#!/usr/bin/env bash
# finalize.sh — gaia-tech-debt-review skill finalize
#
# Carve-out documentation:
# This finalize.sh does NOT enforce GAIA_FINALIZE_SENTINEL_REQUIRED
# (the fail-closed Val sentinel pattern shipped by /gaia-triage-findings
# and /gaia-retro). The intentional carve-out: fail-closed-on-Val applies
# ONLY to skills that mutate .gaia/state/action-items.yaml (triage,
# retro). /gaia-tech-debt-review produces a read-and-write-dashboard
# artifact only (tech-debt-dashboard.md) and does NOT touch action-items;
# the dashboard is regenerable from scan-findings.sh on every invocation,
# so a missing-Val-sentinel run still produces correct output. The
# operator is not blocked by a stale Val-sentinel mismatch.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-tech-debt-review/finalize.sh"
WORKFLOW_NAME="tech-debt-review"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 7 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

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
