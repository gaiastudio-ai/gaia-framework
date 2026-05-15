#!/usr/bin/env bash
# finalize.sh — gaia-retro skill finalize (E28-S64)
#
# Shared finalize pattern from the E28-S17/S19/S21 foundation work.
# Writes checkpoint and emits lifecycle event on completion.
#
# Exit codes:
#   0 — finalize succeeded
#   1 — checkpoint write or lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-retro/finalize.sh"
WORKFLOW_NAME="retrospective"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Val-sidecar sentinel precondition (E92-S2 / FR-OEXP-2) ----------
#
# When GAIA_FINALIZE_SENTINEL_REQUIRED is set (the SKILL.md Step 7 contract
# exports it), assert a Val sidecar entry was written AFTER the run-started
# checkpoint marker. Mirrors gaia-add-feature/finalize.sh:51-82 (E83-S1
# fail-closed pattern) and the sibling triage-findings/finalize.sh guard.
#
# Legacy fixtures that do NOT export the env var get the prior unconditional
# behavior (backward-compat).
if [ -n "${GAIA_FINALIZE_SENTINEL_REQUIRED:-}" ]; then
  PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}"
  SIDECAR_LOG="$PROJECT_ROOT/_memory/validator-sidecar/decision-log.md"
  CHECKPOINT_MARKER="${CHECKPOINT_PATH:-$PROJECT_ROOT/_memory/checkpoints}/retrospective.json"

  if [ ! -f "$SIDECAR_LOG" ]; then
    die "Val sidecar write missing — Step 7 must be invoked before finalize (no decision-log at $SIDECAR_LOG)"
  fi
  if [ ! -f "$CHECKPOINT_MARKER" ]; then
    die "Val sidecar write missing — Step 7 must be invoked before finalize (no run checkpoint at $CHECKPOINT_MARKER)"
  fi
  if [ "$SIDECAR_LOG" -ot "$CHECKPOINT_MARKER" ]; then
    die "Val sidecar write missing — Step 7 must be invoked before finalize (decision-log older than run checkpoint)"
  fi
  log "Val sidecar sentinel: PRESENT (decision-log newer than run checkpoint)"
fi

# ---------- 1. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 6 >/dev/null 2>&1; then
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
