#!/usr/bin/env bash
# setup.sh — gaia-test-perf action skill setup (E73-S2).
#
# Mirrors gaia-test-e2e/setup.sh:
#   1. Resolve config via resolve-config.sh
#   2. Load checkpoint state
#
# Exit codes:
#   0 — setup succeeded
#   1 — config resolution or checkpoint load failed
#
# POSIX discipline: bash 3.2 / macOS-compatible, set -euo pipefail, LC_ALL=C.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-perf/setup.sh"
WORKFLOW_NAME="test-perf"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

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
else
  log "resolve-config.sh not found — skipping config resolution"
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
else
  log "checkpoint.sh not found — skipping checkpoint load"
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
