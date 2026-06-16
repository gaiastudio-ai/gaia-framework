#!/usr/bin/env bash
# setup.sh — test-manual skill setup
#
# Mechanical extension of the shared reference implementation
# (gaia-check-dod/scripts/setup.sh). Only WORKFLOW_NAME and
# SCRIPT_NAME differ — the body follows the shared pattern.
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Load the checkpoint state for this workflow
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution or checkpoint load failed
#
# POSIX discipline: bash with [ ] tests (no [[ ]]); no indexed arrays.
# LC_ALL=C for deterministic output. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-manual/setup.sh"
WORKFLOW_NAME="test-manual"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-test-manual/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

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
# Export every KEY='VALUE' line the resolver emits so downstream tools
# (checkpoint.sh) pick them up from the environment.
while IFS= read -r line; do
  case "$line" in
    [A-Z_]*=*) eval "export $line" ;;
  esac
done <<<"$config_output"

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
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint load (non-fatal)"
fi

# ---------- 3. Surface passthrough ----------
# If MANUAL_TEST_SURFACE is set by the caller, export it for downstream
# scripts (surface-adapter.sh, dispatch-surface.sh). Default is empty,
# which lets the SKILL.md orchestration default to "api".
if [ -n "${MANUAL_TEST_SURFACE:-}" ]; then
  export MANUAL_TEST_SURFACE
  log "surface override: $MANUAL_TEST_SURFACE"
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
