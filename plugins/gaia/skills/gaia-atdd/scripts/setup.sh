#!/usr/bin/env bash
# setup.sh — ATDD skill setup (E28-S83)
#
# Mechanical extension of the Cluster 4 reference implementation.
# Adds ATDD-specific prereq gates:
#   - Story file must exist for the given story key
#
# Responsibilities (per brief Cluster 4):
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (story file existence)
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

SCRIPT_NAME="gaia-atdd/setup.sh"
WORKFLOW_NAME="atdd"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-atdd/scripts/setup.sh → ../../../scripts
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

# ---------- 2. Story-file existence (E80-S1: Option B) ----------
# The ATDD skill body performs its own detailed validation, so this is a
# lightweight pre-check only. Earlier revisions called
# `validate-gate.sh story_file_exists` here, but that gate type is not
# implemented in validate-gate.sh — it always exited non-zero and emitted
# a false-positive WARNING line on every /gaia-atdd invocation. Per
# E80-S1 AC7 we drop the validate-gate.sh call entirely and rely on the
# downstream skill-body validation for the authoritative message.
:

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
