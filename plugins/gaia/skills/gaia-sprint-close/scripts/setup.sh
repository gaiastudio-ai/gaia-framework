#!/usr/bin/env bash
# setup.sh — gaia-sprint-close skill setup (E81-S5).
#
# Shared setup pattern from the E28-S17/S19/S21 foundation work.
# Resolves config, validates gates, loads checkpoint state.
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution, gate validation, or checkpoint load failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-close/setup.sh"
WORKFLOW_NAME="sprint-close"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Resolve config ----------
if [ -x "$RESOLVE_CONFIG" ]; then
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
fi

# ---------- 2. Load checkpoint state ----------
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
fi

# ---------- 3. Emit lifecycle event (skill_invocation) ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type skill_invocation --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    log "lifecycle-event.sh emit failed — continuing (non-fatal)"
  fi
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
