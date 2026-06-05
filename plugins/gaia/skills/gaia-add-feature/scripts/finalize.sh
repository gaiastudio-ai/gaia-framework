#!/usr/bin/env bash
# finalize.sh — add-feature skill finalize
#
# Responsibilities:
#   1. Write a checkpoint via the shared checkpoint.sh foundation script
#   2. Emit a lifecycle event via lifecycle-event.sh for the tailing sync agent
#
# Fail-closed Val gate:
#   0. Validate the Val-dispatch sentinel before any cascade-completion side
#      effects. If the sentinel is missing or malformed, exit non-zero with a
#      stderr message that names the failure mode and points the user back
#      to a parent orchestrator thread.
#
# The sentinel lives at:
#   $CHECKPOINT_PATH/add-feature-${FEATURE_ID}-val-dispatched.json
# Required keys (validated via `jq -e`):
#   status   — enum ∈ {PASS, WARNING, CRITICAL, UNVERIFIED}
#   summary  — string
#   findings — array
#   agent    — must equal "val"
#
# The guard is skipped only when FEATURE_ID is not exported. That degrades
# safely for legacy test fixtures that exercise finalize.sh without driving
# the full skill — a guarded mode where FEATURE_ID is set
# enforces the gate; an unguarded mode without FEATURE_ID retains the prior
# behavior. The /gaia-add-feature SKILL.md Step 9 wiring exports FEATURE_ID
# unconditionally, so production paths always flow through the guard.
#
# Exit codes:
#   0 — finalize succeeded
#   1 — sentinel missing/malformed, checkpoint write, or lifecycle event
#       emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-add-feature/finalize.sh"
WORKFLOW_NAME="add-feature"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"
RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Val-gate sentinel precondition ----------

# Resolve CHECKPOINT_PATH if not already set.
if [ -z "${CHECKPOINT_PATH:-}" ] && [ -x "$RESOLVE_CONFIG" ]; then
  while IFS= read -r line; do
    case "$line" in
      checkpoint_path=*)
        v="${line#checkpoint_path=}"
        v="${v#\'}"; v="${v%\'}"
        CHECKPOINT_PATH="$v"
        export CHECKPOINT_PATH
        ;;
      CHECKPOINT_PATH=*)
        v="${line#CHECKPOINT_PATH=}"
        v="${v#\'}"; v="${v%\'}"
        CHECKPOINT_PATH="$v"
        export CHECKPOINT_PATH
        ;;
    esac
  done < <("$RESOLVE_CONFIG" 2>/dev/null || true)
fi

# When FEATURE_ID is exported, run the full guard. The /gaia-add-feature
# SKILL.md exports FEATURE_ID before invoking finalize.sh — production code
# paths always flow through the guard. Legacy fixtures that do not export
# FEATURE_ID retain the prior behavior.
if [ -n "${FEATURE_ID:-}" ]; then
  if [ -z "${CHECKPOINT_PATH:-}" ]; then
    die "Val gate sentinel missing — CHECKPOINT_PATH unresolved; re-invoke from a parent orchestrator thread"
  fi

  sentinel="$CHECKPOINT_PATH/add-feature-${FEATURE_ID}-val-dispatched.json"

  if [ ! -f "$sentinel" ]; then
    die "Val gate sentinel missing at ${sentinel} — re-invoke from a parent orchestrator thread"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    die "Val gate sentinel cannot be validated — jq not available; re-invoke from a parent orchestrator thread"
  fi

  # Structural validation. We use jq -e so a missing key or wrong type
  # exits non-zero. Each check is run separately so the stderr message
  # names the offending field.

  # 1. Parseable JSON
  if ! jq -e . "$sentinel" >/dev/null 2>&1; then
    die "Val gate sentinel malformed at ${sentinel} — not valid JSON; re-invoke from a parent orchestrator thread"
  fi

  # 2. status key present and within enum
  status_val="$(jq -r '.status // "<MISSING>"' "$sentinel" 2>/dev/null)"
  if [ "$status_val" = "<MISSING>" ]; then
    die "Val gate sentinel malformed — missing required key: status"
  fi
  case "$status_val" in
    PASS|WARNING|CRITICAL|UNVERIFIED) ;;
    *) die "Val gate sentinel malformed — invalid status enum value: ${status_val} (expected PASS|WARNING|CRITICAL|UNVERIFIED)" ;;
  esac

  # 3. agent must equal "val"
  agent_val="$(jq -r '.agent // "<MISSING>"' "$sentinel" 2>/dev/null)"
  if [ "$agent_val" = "<MISSING>" ]; then
    die "Val gate sentinel malformed — missing required key: agent"
  fi
  if [ "$agent_val" != "val" ]; then
    die "Val gate sentinel malformed — agent key must equal \"val\" (got: ${agent_val})"
  fi

  # 4. summary is a string
  if ! jq -e '.summary | type == "string"' "$sentinel" >/dev/null 2>&1; then
    die "Val gate sentinel malformed — summary key missing or not a string"
  fi

  # 5. findings is an array
  if ! jq -e '.findings | type == "array"' "$sentinel" >/dev/null 2>&1; then
    die "Val gate sentinel malformed — findings key missing or not an array"
  fi

  log "Val gate sentinel validated: $sentinel (status=${status_val})"
fi

# ---------- 1. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 8 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

# ---------- 2. Emit lifecycle event ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    die "lifecycle-event.sh emit failed for $WORKFLOW_NAME"
  fi
  log "lifecycle event emitted for $WORKFLOW_NAME"
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event emission (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
