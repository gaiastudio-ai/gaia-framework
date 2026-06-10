#!/usr/bin/env bash
# finalize.sh — triage-findings skill finalize
#
# Shared finalize pattern. Writes checkpoint and emits lifecycle event on completion.
#
# Exit codes:
#   0 — finalize succeeded
#   1 — checkpoint write or lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-triage-findings/finalize.sh"
WORKFLOW_NAME="triage-findings"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Val-sidecar sentinel precondition ----------
#
# When GAIA_FINALIZE_SENTINEL_REQUIRED is set (the SKILL.md Step 7 contract
# exports it), assert a Val sidecar entry was written AFTER the run-started
# checkpoint marker. Mirrors gaia-add-feature/finalize.sh fail-closed pattern.
# Operators see a canonical, grep-able error string if Step 7 was skipped.
#
# Legacy fixtures that do NOT export the env var get the prior unconditional
# behavior (Test D backward-compat).
if [ -n "${GAIA_FINALIZE_SENTINEL_REQUIRED:-}" ]; then
  PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}"
  # Canonical .gaia/ paths only; the legacy _memory
  # fallbacks were removed with the consolidation migration. Env CHECKPOINT_PATH wins.
  SIDECAR_LOG="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  if [ -n "${CHECKPOINT_PATH:-}" ]; then
    CHECKPOINT_MARKER="$CHECKPOINT_PATH/triage-findings.json"
  else
    CHECKPOINT_MARKER="$PROJECT_ROOT/.gaia/memory/checkpoints/triage-findings.json"
  fi

  if [ ! -f "$SIDECAR_LOG" ]; then
    die "Val sidecar write missing — Step 7 must be invoked before finalize (no decision-log at $SIDECAR_LOG)"
  fi
  if [ ! -f "$CHECKPOINT_MARKER" ]; then
    die "Val sidecar write missing — Step 7 must be invoked before finalize (no run checkpoint at $CHECKPOINT_MARKER)"
  fi
  # Out-of-window check: sidecar mtime MUST be newer than the run checkpoint.
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

# ---------- 3. Write the per-sprint triage proof-of-run sentinel ----------
# /gaia-sprint-close requires this sentinel before it will close the active
# sprint (triage is a mandatory sprint-close prerequisite). Best-effort: a
# missing sprint-status.yaml (e.g. a single-story --story-key run with no
# active sprint) simply skips the write — non-fatal.
TRIAGE_SENTINEL="$SCRIPT_DIR/triage-sentinel.sh"
SPRINT_STATUS_FILE="${PROJECT_ROOT:-.}/.gaia/state/sprint-status.yaml"
if [ -x "$TRIAGE_SENTINEL" ] && [ -f "$SPRINT_STATUS_FILE" ]; then
  SPRINT_ID=$(awk -F: '/^sprint_id[[:space:]]*:/ { sub(/^sprint_id[[:space:]]*:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit }' "$SPRINT_STATUS_FILE")
  if [ -n "$SPRINT_ID" ]; then
    if "$TRIAGE_SENTINEL" write --sprint-id "$SPRINT_ID" --checkpoints-dir "${PROJECT_ROOT:-.}/.gaia/memory/checkpoints" >/dev/null 2>&1; then
      log "triage proof-of-run sentinel written for sprint $SPRINT_ID"
    else
      log "triage-sentinel write failed for sprint $SPRINT_ID (non-fatal)"
    fi
  fi
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
