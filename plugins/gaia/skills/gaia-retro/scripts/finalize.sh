#!/usr/bin/env bash
# finalize.sh — gaia-retro skill finalize (E28-S64)
#
# Shared finalize pattern from the E28-S17/S19/S21 foundation work.
# Writes checkpoint and emits lifecycle event on completion.
#
# Exit codes:
#   0 — finalize succeeded
#   1 — checkpoint write or lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-retro/finalize.sh"
WORKFLOW_NAME="retrospective"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Val-sidecar sentinel precondition (E92-S2 / FR-OEXP-2) ----------
#
# When GAIA_FINALIZE_SENTINEL_REQUIRED is set (the SKILL.md Step 7 contract
# exports it), assert a Val sidecar entry was written AFTER the run-started
# checkpoint marker. Mirrors gaia-add-feature/finalize.sh:51-82 (E83-S1
# fail-closed pattern) and the sibling triage-findings/finalize.sh guard.
#
# Legacy fixtures that do NOT export the env var get the prior unconditional
# behavior (backward-compat).
if [ -n "${GAIA_FINALIZE_SENTINEL_REQUIRED:-}" ]; then
  PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}"
  # AF-2026-05-27-3 (ADR-111): canonical .gaia/ paths only; legacy _memory
  # fallbacks removed with the consolidation migration.
  SIDECAR_LOG="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  # AF-2026-05-29-1 / Test08 F-19: the F-21 (AF-2026-05-26-1) comment was wrong
  # — write-checkpoint.sh actually emits
  # `${CHECKPOINT_ROOT}/{skill_name}/{ts}-step-{N}.json` (JSON, per-skill subdir,
  # timestamped). Looking for the literal `retrospective.yaml` always failed the
  # sentinel check unless an operator manually touched the file. Resolve the
  # marker via two-form acceptance: (a) the canonical write-checkpoint.sh JSON
  # form (preferred); (b) the legacy literal `retrospective.yaml` (kept for
  # call sites that explicitly stamp it). Env CHECKPOINT_PATH override wins.
  _ck_root=""
  if [ -n "${CHECKPOINT_PATH:-}" ]; then
    _ck_root="$CHECKPOINT_PATH"
  else
    _ck_root="$PROJECT_ROOT/.gaia/memory/checkpoints"
  fi
  CHECKPOINT_MARKER=""
  # (a) canonical write-checkpoint.sh form — pick the newest step file under
  # the per-skill subdir.
  if [ -d "$_ck_root/retrospective" ]; then
    CHECKPOINT_MARKER="$(ls -1t "$_ck_root/retrospective"/*-step-*.json 2>/dev/null | head -1 || true)"
  fi
  # (b) legacy literal — accept the older shape too.
  if [ -z "$CHECKPOINT_MARKER" ] && [ -f "$_ck_root/retrospective.yaml" ]; then
    CHECKPOINT_MARKER="$_ck_root/retrospective.yaml"
  fi

  if [ ! -f "$SIDECAR_LOG" ]; then
    die "Val sidecar write missing — Step 7 must be invoked before finalize (no decision-log at $SIDECAR_LOG)"
  fi
  if [ -z "$CHECKPOINT_MARKER" ] || [ ! -f "$CHECKPOINT_MARKER" ]; then
    die "Val sidecar write missing — Step 7 must be invoked before finalize (no run checkpoint found at $_ck_root/retrospective/*-step-*.json OR $_ck_root/retrospective.yaml)"
  fi
  # F-026 (Test04) — KNOWN FRAGILITY of the mtime-based sentinel.
  # This `-ot` check asserts the sidecar decision-log was touched AFTER the run
  # checkpoint, as a proxy for "Step 7 (Val sidecar write) actually ran this
  # invocation". It is intentionally lightweight but NOT tamper-proof: any
  # unrelated process that touches decision-log.md refreshes its mtime and can
  # satisfy this check without a real Val write; conversely a fast re-finalize
  # can race the mtime granularity. A robust replacement is an explicit
  # (workflow, run_id) -> decision_id ledger keyed to THIS run, rather than a
  # filesystem-mtime comparison — tracked as a future hardening (do not rely on
  # this guard for adversarial tamper-resistance; it is a sequencing sanity
  # check, not a security control). The same caveat applies to the sibling
  # gaia-tech-debt-review and gaia-triage-findings finalize.sh guards.
  if [ "$SIDECAR_LOG" -ot "$CHECKPOINT_MARKER" ]; then
    die "Val sidecar write missing — Step 7 must be invoked before finalize (decision-log older than run checkpoint)"
  fi
  log "Val sidecar sentinel: PRESENT (decision-log newer than run checkpoint)"
fi

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

log "finalize complete for $WORKFLOW_NAME"
exit 0
