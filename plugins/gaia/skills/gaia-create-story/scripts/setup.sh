#!/usr/bin/env bash
# setup.sh — create-story skill setup
#
# Mechanical extension of the gaia-brainstorm/scripts/setup.sh reference
# implementation. Adds create-story-specific prereq gates:
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

SCRIPT_NAME="gaia-create-story/setup.sh"
WORKFLOW_NAME="create-story"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-create-story/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. YOLO mode detection ----------
# Scan positional args ($1, $2) and the $ARGUMENTS env var for the literal
# `yolo` keyword or `--yolo` flag. Export YOLO_MODE so the SKILL.md body can
# branch on it and emit a single log line so the LLM can read the state.
#
# Hard rule: YOLO_MODE only suppresses interactive prompts. It MUST NOT bypass:
#   - Step 1 existing-story-status HALT gate
#   - Step 6 3-attempt cap or terminal FAILED verdict
__arg1="${1:-}"
__arg2="${2:-}"
__args_blob=" ${__arg1} ${__arg2} ${ARGUMENTS:-} "
if [[ "$__args_blob" == *" yolo "* ]] || [[ "$__args_blob" == *" --yolo "* ]]; then
  export YOLO_MODE=true
else
  export YOLO_MODE=false
fi
echo "$SCRIPT_NAME: yolo_mode=${YOLO_MODE}" >&2

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
#
# Resolve planning_artifacts via resolve-config.sh. Project overrides flow
# through the resolver; the resolver returns the {project_root}/docs/
# {planning-key} default when no override is present. HALT on resolver
# non-zero exit — the skill MUST NOT silently fall back to a hardcoded path.
# Normalize whitespace and a trailing slash on the resolved value so the path
# join is deterministic across project layouts.
if pa_resolved=$("$RESOLVE_CONFIG" planning_artifacts 2>&1); then
  # Strip leading/trailing whitespace and a single trailing slash.
  pa_resolved=${pa_resolved#"${pa_resolved%%[![:space:]]*}"}
  pa_resolved=${pa_resolved%"${pa_resolved##*[![:space:]]}"}
  pa_resolved=${pa_resolved%/}
  # Drop a leading `./` for callers that pass relative form.
  pa_resolved=${pa_resolved#./}
  PLANNING_ARTIFACTS="${PLANNING_ARTIFACTS:-$pa_resolved}"
else
  log "resolve-config.sh planning_artifacts failed:"
  printf '%s\n' "$pa_resolved" >&2
  die "HALT: resolver failed for planning_artifacts (exit non-zero) — refusing silent fallback"
fi
EPICS_PATH="${PLANNING_ARTIFACTS}/epics-and-stories.md"

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
