#!/usr/bin/env bash
# finalize.sh — Cluster 11 gaia-ci-edit skill finalize (E28-S86, fixed E28-S199)
#
# Originally a mechanical copy of the Cluster 9 reference finalize.sh
# (E28-S66 gaia-code-review). E28-S197 triage (F3 / ContractBug) identified
# the unconditional `validate-gate.sh ci_setup_exists` invocation as
# inappropriate for ci-edit: the skill only edits an existing setup file,
# so on a fresh fixture (no prior setup) the gate fails tautologically and
# masks the real error. E28-S199 replaces the unconditional call with a
# conditional guard driven by a runtime marker written by setup.sh.
#
# Conditional-guard contract:
#   setup.sh probes for .gaia/artifacts/test-artifacts/ci-setup.md at invocation time.
#   If present, it writes ${PROJECT_ROOT:-$PWD}/.gaia/run-state/ci-edit-had-prior-setup
#   as a marker. finalize.sh inspects the same marker:
#     - marker absent  → no prior setup existed when the edit started;
#                       skip the ci_setup_exists post-check entirely
#                       (fresh-fixture runs exit 0 cleanly — AC5).
#     - marker present → a prior setup was observed by setup.sh;
#                       the gate runs as a regression guard and will exit
#                       non-zero if the edit body erased the file (AC6).
#   finalize.sh removes the marker on every exit path so the next edit
#   run re-probes fresh — the marker is per-run, not sticky.
#
# Responsibilities:
#   1. Conditional post-edit gate verification (marker-gated — E28-S199)
#   2. Write a checkpoint via the shared checkpoint.sh foundation script
#   3. Emit a lifecycle event via lifecycle-event.sh for the tailing sync agent
#
# Exit codes:
#   0 — finalize succeeded
#   1 — gate validation (when marker present), checkpoint write, or
#       lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-ci-edit/finalize.sh"
WORKFLOW_NAME="ci-edit"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

RUN_STATE_DIR="${PROJECT_ROOT:-$PWD}/.gaia/run-state"
HAD_PRIOR_SETUP_MARKER="$RUN_STATE_DIR/ci-edit-had-prior-setup"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# cleanup_marker — remove the had_prior_setup marker regardless of path.
# Registered as an EXIT trap so genuine failures in the checkpoint or
# lifecycle-event emission below still leave the run-state directory
# consistent for the next invocation.
cleanup_marker() {
  if [ -f "$HAD_PRIOR_SETUP_MARKER" ]; then
    rm -f "$HAD_PRIOR_SETUP_MARKER" 2>/dev/null || true
  fi
}
trap cleanup_marker EXIT

# ---------- 1. Conditional post-edit gate verification (E28-S199) ----------
if [ -f "$HAD_PRIOR_SETUP_MARKER" ]; then
  # setup.sh observed a prior .gaia/artifacts/test-artifacts/ci-setup.md. The gate
  # runs as a regression guard — if the edit erased the setup file, the
  # gate fails and we exit non-zero (AC6).
  if [ -x "$VALIDATE_GATE" ]; then
    if ! "$VALIDATE_GATE" ci_setup_exists 2>&1; then
      die "validate-gate.sh: ci_setup_exists gate failed — CI setup output not found"
    fi
    log "validate-gate.sh: ci_setup_exists gate passed (regression guard — prior setup observed)"
  else
    die "validate-gate.sh not found at $VALIDATE_GATE — cannot verify CI gate (E28-S15 dependency)"
  fi
else
  # No prior setup was observed by setup.sh (fresh fixture, first run, or
  # nothing to guard against). Skip the gate entirely — a post-check here
  # would be tautological and would mask real errors (AC5 / E28-S197 F3).
  log "no had_prior_setup marker — skipping ci_setup_exists post-check (fresh-fixture path)"
fi

# ---------- 2. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 8 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

# ---------- 3. Emit lifecycle event ----------
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
