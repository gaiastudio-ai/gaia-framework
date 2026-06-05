#!/usr/bin/env bash
# setup.sh — gaia-document-project skill setup
#
# Follows the shared setup.sh pattern.
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Load any prior checkpoint state for this workflow (non-fatal on miss)
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution failed, or a required foundation script is missing/non-executable

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-document-project/setup.sh"
WORKFLOW_NAME="gaia-document-project"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="${PLUGIN_SCRIPTS_DIR_OVERRIDE:-$(cd "$SCRIPT_DIR/../../../scripts" && pwd)}"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Resolve config (AC-EC2: fail-fast if missing/non-executable) ----------
if [ ! -f "$RESOLVE_CONFIG" ]; then
  die "resolve-config.sh not found at $RESOLVE_CONFIG — cannot proceed (AC-EC2: missing foundation script)"
fi
if [ ! -x "$RESOLVE_CONFIG" ]; then
  die "resolve-config.sh at $RESOLVE_CONFIG is not executable (AC-EC2: non-executable foundation script)"
fi
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

# ---------- 2. Load checkpoint state (non-fatal on miss) ----------
if [ -x "$CHECKPOINT" ]; then
  if "$CHECKPOINT" read --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    log "checkpoint loaded for $WORKFLOW_NAME"
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      log "no prior checkpoint for $WORKFLOW_NAME — fresh run"
    else
      log "checkpoint.sh read returned non-zero ($rc) — continuing fresh"
    fi
  fi
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint load (non-fatal)"
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
