#!/usr/bin/env bash
# finalize.sh — Cluster 11 gaia-trace skill finalize (E28-S85)
#
# Mechanical copy of the Cluster 9 reference implementation authored under
# E28-S66 (gaia-code-review/scripts/finalize.sh). Only WORKFLOW_NAME and
# SCRIPT_NAME differ — the body is byte-identical to the reference.
#
# Responsibilities (per brief Cluster 11):
#   1. Write a checkpoint via the shared checkpoint.sh foundation script
#   2. Emit a lifecycle event via lifecycle-event.sh for the tailing sync agent
#
# Exit codes:
#   0 — finalize succeeded
#   1 — checkpoint write or lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-trace/finalize.sh"
WORKFLOW_NAME="traceability"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 6 >/dev/null 2>&1; then
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

# ---------- 4. Auto-save session memory (E45-S3 / ADR-061) ----------
# Phase 1-3 skills auto-save a session summary to the agent sidecar via
# the shared lib helper. Phase 4 skills (e.g. /gaia-dev-story) short-
# circuit to a no-op so the interactive prompt mandated by ADR-057 /
# FR-YOLO-2(f) is preserved. Failure is non-blocking — the auto-save
# helper itself logs warnings to stderr but never affects this script's
# exit code. SKILL_NAME is resolved from the parent directory name so
# the wire-in is identical across all 24 Phase 1-3 finalize.sh files.
AUTOSAVE_LIB="$PLUGIN_SCRIPTS_DIR/lib/auto-save-memory.sh"
SKILL_NAME="$(basename "$(cd "$SCRIPT_DIR/.." && pwd)")"
if [ -f "$AUTOSAVE_LIB" ]; then
  # shellcheck disable=SC1090
  . "$AUTOSAVE_LIB"
  if ! _auto_save_memory "$SKILL_NAME" "${ARTIFACT:-}"; then
    AUTOSAVE_RC=$?
    if [ "$AUTOSAVE_RC" -eq 64 ]; then
      log "auto-save aborted: cannot resolve agent sidecar for skill $SKILL_NAME"
    fi
  fi
else
  log "auto-save-memory.sh not found at $AUTOSAVE_LIB — skipping auto-save (non-fatal)"
fi

# ---------- 5. Matrix-verdict gate (AF-2026-05-24-13 / Test02 F-39) ----------
# Test02 F-39: validate-gate.sh traceability_exists returned exit 0 against
# matrices that declared their OWN verdict as BLOCKED — the check is
# path-based, not semantic. Per the /gaia-readiness-check Critical Rules,
# if the matrix's gate verdict is BLOCKED, downstream must not declare
# traceability_complete: true. F-39 fix: trace finalize surfaces a
# WARNING when its generated matrix declares BLOCKED or FAIL so the
# caller has an explicit signal rather than burying it inside the
# artifact body.
#
# Idempotent: when no matrix is present (skill ran in --dry-run or the
# write was skipped), this block is a silent no-op.
TM_PATHS="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/test-artifacts/strategy/traceability-matrix.md ${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/test-artifacts/traceability-matrix.md"
for tm in $TM_PATHS; do
  if [ -f "$tm" ] && [ -s "$tm" ]; then
    # Look for the matrix's self-declared verdict in the first ~200 lines.
    # Canonical form: a line like "Verdict: BLOCKED" or "**Gate verdict:** BLOCKED"
    if head -200 "$tm" 2>/dev/null | grep -qiE '(verdict|gate.*verdict)[^a-zA-Z]+(BLOCKED|FAILED|FAIL)'; then
      log "WARNING: traceability matrix at $tm declares its own verdict as BLOCKED/FAIL — downstream /gaia-readiness-check should NOT mark traceability_complete: true (F-39 mitigation; path-based gates pass but semantic gate fails)"
    fi
    break
  fi
done

log "finalize complete for $WORKFLOW_NAME"
exit 0
