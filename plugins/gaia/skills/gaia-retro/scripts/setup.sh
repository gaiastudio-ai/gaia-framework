#!/usr/bin/env bash
# setup.sh — gaia-retro skill setup
#
# Shared setup pattern from the foundation work.
# Resolves config, validates gates, loads checkpoint state.
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution, gate validation, or checkpoint load failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-retro/setup.sh"
WORKFLOW_NAME="retrospective"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Resolve config ----------
[ -x "$RESOLVE_CONFIG" ] || die "resolve-config.sh not found or not executable at $RESOLVE_CONFIG"
if ! config_output=$("$RESOLVE_CONFIG" 2>&1); then
  log "resolve-config.sh failed:"
  printf '%s\n' "$config_output" >&2
  exit 1
fi
while IFS= read -r line; do
  case "$line" in
    [A-Z_]*=*) eval "export $line" ;;
  esac
done <<<"$config_output"

# ---------- 2. Validate gate (prereqs) ----------
# retrospective requires sprint-status.yaml to exist. Run a file_exists gate.
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" file_exists >/dev/null 2>&1; then
    die "validate-gate.sh pre-start gate failed for $WORKFLOW_NAME"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate (non-fatal)"
fi

# ---------- 3. Load checkpoint state ----------
if [ -x "$CHECKPOINT" ]; then
  if "$CHECKPOINT" read --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    log "checkpoint loaded for $WORKFLOW_NAME"
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      log "no prior checkpoint for $WORKFLOW_NAME — fresh run"
    else
      die "checkpoint.sh read failed with exit $rc"
    fi
  fi
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint load (non-fatal)"
fi

# ---------- 3b. Stamp the run-started checkpoint ----------
# finalize.sh's GAIA_FINALIZE_SENTINEL_REQUIRED guard expects a
# write-checkpoint.sh-produced JSON under
# .gaia/memory/checkpoints/retrospective/*-step-*.json — finalize compares
# the Val sidecar decision-log mtime against this checkpoint. Without the
# stamp, finalize.sh self-HALTs even on a clean retro run because the SKILL
# prose (Step 4..) never invokes write-checkpoint.sh. Stamp it here at
# setup so the marker exists for finalize regardless of whether downstream
# steps call write-checkpoint again later.
WRITE_CHECKPOINT="$PLUGIN_SCRIPTS_DIR/write-checkpoint.sh"
if [ -x "$WRITE_CHECKPOINT" ]; then
  if ! "$WRITE_CHECKPOINT" "$WORKFLOW_NAME" 0 stage=setup-complete >/dev/null 2>&1; then
    log "write-checkpoint.sh stamp failed at setup — finalize may self-HALT (non-fatal here)"
  fi
else
  log "write-checkpoint.sh not found at $WRITE_CHECKPOINT — skipping setup-stage stamp (non-fatal)"
fi

# ---------- 4. Emit lifecycle event (skill_invocation) ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type skill_invocation --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    log "lifecycle-event.sh emit failed — continuing (non-fatal)"
  fi
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event (non-fatal)"
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
