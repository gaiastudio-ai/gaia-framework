#!/usr/bin/env bash
# setup.sh — gaia-val-save skill setup
#
# Validates that the validator-sidecar memory path is accessible.
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Verify memory path is accessible (create validator-sidecar dir if needed)
#   3. Load the checkpoint state for this workflow
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution or checkpoint load failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-val-save/setup.sh"
WORKFLOW_NAME="gaia-val-save"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="${PLUGIN_SCRIPTS_DIR_OVERRIDE:-$(cd "$SCRIPT_DIR/../../../scripts" && pwd)}"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

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
    MEMORY_PATH=*|PROJECT_ROOT=*|PROJECT_PATH=*)
      eval "export $line" ;;
  esac
done <<< "$config_output"

# ---------- 2. Verify memory path (.gaia/ canonical) ----------
# .gaia/memory is the only memory tree; legacy _memory fallback removed.
# Env override wins.
if [ -z "${MEMORY_PATH:-}" ]; then
  MEMORY_PATH=".gaia/memory"
fi
SIDECAR_DIR="${MEMORY_PATH}/validator-sidecar"
if [ ! -d "$SIDECAR_DIR" ]; then
  log "validator-sidecar directory not found at $SIDECAR_DIR — will be created on first save"
fi

# ---------- 3. Load checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  "$CHECKPOINT" load "$WORKFLOW_NAME" 2>/dev/null || true
fi

log "setup complete"
exit 0
