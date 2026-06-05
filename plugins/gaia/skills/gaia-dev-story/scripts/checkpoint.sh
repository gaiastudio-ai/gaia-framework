#!/usr/bin/env bash
# checkpoint.sh — gaia-dev-story PostToolUse hook target
#
# This is the skill-local checkpoint wrapper invoked by the PostToolUse hook.
# It translates the simple `checkpoint.sh write gaia-dev-story` invocation
# into the shared foundation checkpoint.sh's --workflow/--step contract.
#
# PostToolUse hooks fire after every Edit/Write tool invocation. This script
# uses --step 0 as a sentinel value to distinguish hook-triggered checkpoints
# from explicit workflow-step checkpoints.
#
# The write is atomic: the shared checkpoint.sh writes to a temp file and
# renames into place. This script is safe to call from rapid/parallel tool
# invocations.
#
# Usage (from PostToolUse hook):
#   checkpoint.sh write gaia-dev-story
#
# Environment:
#   CHECKPOINT_PATH — required. Set by setup.sh or resolve-config.sh.
#   CLAUDE_SKILL_DIR — optional. If unset, logs a warning but continues.
#
# Exit codes:
#   0 — checkpoint written (or skipped with warning)
#   1 — hard failure

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/checkpoint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- Validate environment ----------
if [ -z "${CLAUDE_SKILL_DIR:-}" ]; then
  log "WARNING: CLAUDE_SKILL_DIR is not set — checkpoint may not resolve shared scripts correctly"
fi

# ---------- Parse arguments ----------
if [ $# -lt 2 ]; then
  die "usage: checkpoint.sh write <workflow_name>"
fi

SUBCOMMAND="$1"
WORKFLOW_NAME="$2"

if [ "$SUBCOMMAND" != "write" ]; then
  die "unsupported subcommand: $SUBCOMMAND (only 'write' is supported from PostToolUse hook)"
fi

# ---------- Resolve shared checkpoint.sh ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_CHECKPOINT="$SCRIPT_DIR/../../../scripts/checkpoint.sh"

if [ ! -x "$SHARED_CHECKPOINT" ]; then
  log "ERROR: shared checkpoint.sh not found at $SHARED_CHECKPOINT"
  exit 1
fi

# ---------- Ensure CHECKPOINT_PATH ----------
if [ -z "${CHECKPOINT_PATH:-}" ]; then
  # Try to resolve from config
  RESOLVE_CONFIG="$SCRIPT_DIR/../../../scripts/resolve-config.sh"
  if [ -x "$RESOLVE_CONFIG" ]; then
    config_output=$("$RESOLVE_CONFIG" 2>&1) || true
    while IFS= read -r line; do
      case "$line" in
        CHECKPOINT_PATH=*) eval "export $line" ;;
      esac
    done <<<"$config_output"
  fi
fi

if [ -z "${CHECKPOINT_PATH:-}" ]; then
  # .gaia/memory/checkpoints is the only location —
  # the legacy _memory/checkpoints fallback was removed with the migration.
  log "WARNING: CHECKPOINT_PATH not set — using default .gaia/memory/checkpoints"
  export CHECKPOINT_PATH=".gaia/memory/checkpoints"
fi

mkdir -p "$CHECKPOINT_PATH"

# ---------- Write checkpoint via shared script ----------
# Use --step 0 as sentinel for hook-triggered checkpoints
# This distinguishes them from explicit workflow-step checkpoints
"$SHARED_CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 0
