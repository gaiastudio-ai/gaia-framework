#!/usr/bin/env bash
# setup.sh — Cluster 8 sprint-plan skill setup (E28-S60)
#
# Follows the Cluster 8 shared script pattern established in E28-S17.
# Resolves config via the shared resolve-config.sh foundation script,
# validates prerequisites, and loads checkpoint state.
#
# Prerequisites:
#   - epics-and-stories.md must exist in planning-artifacts/
#   - sprint-state.sh must be available in the plugin scripts tree
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

SCRIPT_NAME="gaia-sprint-plan/setup.sh"
WORKFLOW_NAME="sprint-plan"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-sprint-plan/scripts/setup.sh → ../../../scripts
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

# ---------- 2. Validate gate (sprint-state.sh required) ----------
SPRINT_STATE="$PLUGIN_SCRIPTS_DIR/sprint-state.sh"
[ -x "$SPRINT_STATE" ] || die "sprint-state.sh not found or not executable at $SPRINT_STATE — dependency E28-S11 must be merged first"

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

# ---------- 4. Lifecycle gates (ADR-120 / E103-S3) ----------
# Hard-error when upstream MANDATORY skills' artifacts are missing AND no
# `--bypass` recorded for the active sprint in `.gaia/state/lifecycle-overrides.yaml`.
# Source the E103-S2 helper for bypass reads.

LIFECYCLE_LIB="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts/lib/lifecycle-overrides.sh"
STRICT_HELPER="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts/lib/lifecycle-strict-mode.sh"

# Strict-mode resolution (E103-S5 helper; falls back to ON when helper absent).
strict_mode_on=1
if [ -x "$STRICT_HELPER" ]; then
  if "$STRICT_HELPER" lifecycle_strict_mode_enabled >/dev/null 2>&1; then
    strict_mode_on=1
  else
    strict_mode_on=0
  fi
fi

if [ -f "$LIFECYCLE_LIB" ]; then
  SPRINT_ID_FOR_GATE="${SPRINT_ID:-${sprint_id:-}}"
  bypass_payload=""
  if [ -n "$SPRINT_ID_FOR_GATE" ]; then
    bypass_payload="$(bash "$LIFECYCLE_LIB" read --sprint-id "$SPRINT_ID_FOR_GATE" 2>/dev/null || echo '{"bypasses":[]}')"
  fi
  _has_bypass_for() {
    local skill="$1"
    printf '%s' "$bypass_payload" | jq -e --arg s "$skill" '.bypasses | any(.skill == $s or .skill == ("/" + $s))' >/dev/null 2>&1
  }

  # ---- Gate: traceability-matrix.md ----
  TRACE_ART="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/test-artifacts/traceability-matrix.md"
  if [ ! -f "$TRACE_ART" ]; then
    if _has_bypass_for "gaia-trace"; then
      log "traceability gate bypassed: bypass record found for /gaia-trace"
    elif [ "$strict_mode_on" -eq 0 ]; then
      log "WARNING: traceability-matrix.md not found — would block in strict mode (run /gaia-trace OR --bypass gaia-trace --reason \"<text>\")"
    else
      die "traceability-matrix.md not found; run /gaia-trace OR add --bypass gaia-trace --reason \"<text>\""
    fi
  fi

  # ---- Gate: /gaia-readiness-check PASSED ----
  READINESS_LEDGER="${GAIA_STATE_DIR:-.gaia/state}/readiness-check-ledger.yaml"
  has_passed_readiness=0
  if [ -f "$READINESS_LEDGER" ]; then
    if grep -qE "^[[:space:]]*verdict:[[:space:]]*PASSED" "$READINESS_LEDGER" 2>/dev/null; then
      has_passed_readiness=1
    fi
  fi
  if [ "$has_passed_readiness" -eq 0 ]; then
    if _has_bypass_for "gaia-readiness-check"; then
      log "readiness gate bypassed: bypass record found for /gaia-readiness-check"
    elif [ "$strict_mode_on" -eq 0 ]; then
      log "WARNING: no PASSED /gaia-readiness-check verdict on record — would block in strict mode (run /gaia-readiness-check OR --bypass gaia-readiness-check --reason \"<text>\")"
    else
      die "no PASSED /gaia-readiness-check verdict on record; run /gaia-readiness-check OR add --bypass gaia-readiness-check --reason \"<text>\""
    fi
  fi
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
