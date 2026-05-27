#!/usr/bin/env bash
# finalize.sh — /gaia-sprint-review skill finalize (E93-S3)
#
# Mechanical mirror of /gaia-add-feature/scripts/finalize.sh — same E83
# sentinel-guard precondition + checkpoint write + lifecycle emit pattern.
#
# Responsibilities:
#   1. Validate the E83 Val dispatch sentinel exists when SPRINT_ID is
#      exported (set by the orchestrator at SKILL.md Step 3). The sentinel
#      path is `_memory/checkpoints/sprint-review-${SPRINT_ID}-val-
#      dispatched.json`. A missing or malformed sentinel HALTs with the
#      canonical error string per FR-362 / ADR-063 amendment.
#   2. Write the workflow completion checkpoint.
#   3. Emit the lifecycle event.
#
# Sentinel guard is OPTIONAL — when SPRINT_ID is unset (e.g., the skill
# bailed out at Step 1 pre-condition gate before any Val dispatch), the
# guard is a no-op. Production cascades MUST always export SPRINT_ID
# before invoking finalize.sh; legacy fixtures and short-circuit paths
# may skip.
#
# Exit codes:
#   0 — finalize succeeded.
#   1 — sentinel guard tripped (missing/malformed sentinel) OR checkpoint
#       write failed.
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-review/finalize.sh"
WORKFLOW_NAME="gaia-sprint-review"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. E83 sentinel guard (FR-362, ADR-063 amendment) ----------

# Resolve CHECKPOINT_PATH (CHECKPOINT_PATH env-var override first;
# walk-up from CWD looking for the .gaia/memory/ or legacy _memory/
# project-root marker per E96-S8 smart-fallback discipline).
# Mirrors write-val-sentinel.sh's walk-up — kept inline rather than
# extracted to lib/ because the duplication is bounded to 2 callers
# and the walk-up is a 9-line idiom.
if [ -z "${CHECKPOINT_PATH:-}" ]; then
  cwd="$(pwd)"
  while [ "$cwd" != "/" ]; do
    # AF-2026-05-27-3 (ADR-111): canonical .gaia/memory/checkpoints only; the
    # legacy _memory probe was removed with the consolidation migration.
    if [ -d "$cwd/.gaia/memory/checkpoints" ] || [ -d "$cwd/.gaia/memory" ]; then
      CHECKPOINT_PATH="$cwd/.gaia/memory/checkpoints"
      break
    fi
    cwd="$(dirname "$cwd")"
  done
fi

if [ -n "${SPRINT_ID:-}" ]; then
  SENTINEL="$CHECKPOINT_PATH/sprint-review-${SPRINT_ID}-val-dispatched.json"
  if [ ! -f "$SENTINEL" ]; then
    die "Val gate sentinel missing at $SENTINEL — re-invoke /gaia-sprint-review from a parent orchestrator thread"
  fi
  # Validate sentinel JSON structure.
  if command -v jq >/dev/null 2>&1; then
    jq -e '.sprint_id and .val_return.status' "$SENTINEL" >/dev/null 2>&1 \
      || die "Val gate sentinel malformed at $SENTINEL — required keys missing"
  fi
  log "Val gate sentinel validated: $SENTINEL"
else
  # AF-2026-05-22-9 Bug-12: previously this branch silently downgraded to
  # "skipping sentinel guard" even in production cascades. The legitimate
  # legacy-fixture path now MUST set GAIA_SPRINT_REVIEW_FIXTURE=1 to
  # opt into the no-sentinel path; otherwise this is a hard error so
  # production cascades that forgot to export SPRINT_ID fail loudly
  # instead of bypassing the gate.
  if [ "${GAIA_SPRINT_REVIEW_FIXTURE:-0}" = "1" ]; then
    log "SPRINT_ID unset and GAIA_SPRINT_REVIEW_FIXTURE=1 — skipping sentinel guard (legacy fixture path)"
  else
    die "SPRINT_ID is unset — production cascades MUST export SPRINT_ID; set GAIA_SPRINT_REVIEW_FIXTURE=1 only for legacy fixture invocation"
  fi
fi

# ---------- 2. Checkpoint write ----------

if [ -x "$CHECKPOINT" ]; then
  "$CHECKPOINT" write "$WORKFLOW_NAME" >/dev/null 2>&1 || true
  log "checkpoint written for $WORKFLOW_NAME"
fi

# ---------- 3. Lifecycle event ----------

if [ -x "$LIFECYCLE_EVENT" ]; then
  "$LIFECYCLE_EVENT" emit --workflow "$WORKFLOW_NAME" --event complete >/dev/null 2>&1 || true
  log "lifecycle event emitted for $WORKFLOW_NAME"
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
