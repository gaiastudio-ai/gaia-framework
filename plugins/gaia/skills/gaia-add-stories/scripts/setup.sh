#!/usr/bin/env bash
# setup.sh — add-stories skill setup
#
# Adds add-stories-specific prereq gates:
#   - epics-and-stories.md must exist and be non-empty
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (epics-and-stories.md)
#   3. Load the checkpoint state for this workflow
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution, gate validation, or checkpoint load failed
#
# POSIX discipline: bash with [[ ]] and indexed arrays only. LC_ALL=C for
# deterministic output. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-add-stories/setup.sh"
WORKFLOW_NAME="add-stories"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-add-stories/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
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
# (validate-gate.sh, checkpoint.sh) pick them up from the environment.
while IFS= read -r line; do
  case "$line" in
    [A-Z_]*=*) eval "export $line" ;;
  esac
done <<<"$config_output"

# ---------- 2. Validate gate (epics-and-stories.md required) ----------
# Smart-fallback when PLANNING_ARTIFACTS is not set
if [ -z "${PLANNING_ARTIFACTS:-}" ]; then
  if [ -d ".gaia/artifacts/planning-artifacts" ]; then
    PLANNING_ARTIFACTS=".gaia/artifacts/planning-artifacts"
  else
    PLANNING_ARTIFACTS="docs/planning-artifacts"
  fi
fi
EPICS_PATH="$PLANNING_ARTIFACTS/epics-and-stories.md"

if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" epics_and_stories_exists 2>&1; then
    die "HALT: epics-and-stories.md not found at $EPICS_PATH — run /gaia-create-epics first"
  fi
else
  # Fallback: manual check when validate-gate.sh is not available
  if [ ! -s "$EPICS_PATH" ]; then
    die "HALT: epics-and-stories.md not found or empty at $EPICS_PATH — run /gaia-create-epics first"
  fi
  log "validate-gate.sh not found at $VALIDATE_GATE — used manual check (non-fatal)"
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

log "setup complete for $WORKFLOW_NAME"
exit 0
