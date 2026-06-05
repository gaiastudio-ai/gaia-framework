#!/usr/bin/env bash
# finalize.sh — gaia-deploy-checklist skill finalize
#
# Mechanical copy of the shared reference implementation
# (gaia-code-review/scripts/finalize.sh). Only WORKFLOW_NAME and
# SCRIPT_NAME differ — the body is byte-identical to the reference.
#
# Responsibilities:
#   1. Invoke validate-gate.sh for post-checklist gate verification
#   2. Write a checkpoint via the shared checkpoint.sh foundation script
#   3. Emit a lifecycle event via lifecycle-event.sh for the tailing sync agent
#
# Exit codes:
#   0 — finalize succeeded
#   1 — gate validation, checkpoint write, or lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy-checklist/finalize.sh"
WORKFLOW_NAME="deploy-checklist"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Post-checklist gate verification via validate-gate.sh ----------
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" --multi traceability_exists,ci_setup_exists,readiness_report_exists 2>&1; then
    die "validate-gate.sh: deployment gate verification failed — one or more gates did not pass"
  fi
  log "validate-gate.sh: all deployment gates passed"
else
  die "validate-gate.sh not found at $VALIDATE_GATE — cannot verify deployment gates (validate-gate dependency missing)"
fi

# ---------- 2. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 5 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

# ---------- 3. Emit lifecycle event ----------
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
