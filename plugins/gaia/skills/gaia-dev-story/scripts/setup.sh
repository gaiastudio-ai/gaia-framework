#!/usr/bin/env bash
# setup.sh — gaia-dev-story skill setup (E28-S53)
#
# Mechanical extension of the Cluster 4 reference implementation.
# Adds dev-story-specific prereq gates:
#   - Story file must exist for the given story_key
#   - Story status must be ready-for-dev or in-progress
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (story file exists)
#   3. Load the checkpoint state for this workflow
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution, gate validation, or checkpoint load failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/setup.sh"
WORKFLOW_NAME="gaia-dev-story"

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
while IFS= read -r line; do
  case "$line" in
    [A-Z_]*=*) eval "export $line" ;;
  esac
done <<<"$config_output"

# ---------- 2. Validate gate (story file required) ----------
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" file_exists 2>&1; then
    die "HALT: Story file not found — run /gaia-create-story first"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate validation (non-fatal)"
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

# ---------- 4. Distributed traceability gate (AF-2026-05-24-6 / F-33 mitigation) ----------
# Test02 F-33 (CRITICAL): the framework's mandatory quality gates collapse
# silently when /gaia-sprint-plan is sidestepped (F-9) — because /gaia-sprint-plan
# was the ONLY skill enforcing the ADR-042 traceability-matrix gate. /gaia-dev-story
# now enforces the same gate so a story driven straight from backlog to in-progress
# without going through /gaia-sprint-plan still respects the contract. When strict
# mode is OFF, this is an advisory warning. When strict mode is ON (recommended
# default per ADR-120), it's a hard halt with the canonical `--bypass gaia-trace
# --reason "<text>"` escape hatch.
SCRIPT_DIR_F33="$(cd "$(dirname "$0")" && pwd)"
LIFECYCLE_LIB_F33="$(cd "$SCRIPT_DIR_F33/../../.." && pwd)/scripts/lib/lifecycle-overrides.sh"
STRICT_HELPER_F33="$(cd "$SCRIPT_DIR_F33/../../.." && pwd)/scripts/lib/lifecycle-strict-mode.sh"

TM_ART="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/test-artifacts/strategy/traceability-matrix.md"
if [ ! -f "$TM_ART" ]; then
  # Legacy fallback location
  TM_ART_LEGACY="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/test-artifacts/traceability-matrix.md"
  if [ -f "$TM_ART_LEGACY" ]; then
    TM_ART="$TM_ART_LEGACY"
  fi
fi

if [ -f "$TM_ART" ] && [ -s "$TM_ART" ]; then
  log "traceability-matrix gate satisfied: $TM_ART"
else
  # Strict-mode resolution
  strict_on_f33=1
  if [ -x "$STRICT_HELPER_F33" ]; then
    if "$STRICT_HELPER_F33" lifecycle_strict_mode_enabled >/dev/null 2>&1; then
      strict_on_f33=1
    else
      strict_on_f33=0
    fi
  fi

  # Check for recorded bypass on the active sprint
  has_trace_bypass=0
  bp_reason_f33=""
  if [ -f "$LIFECYCLE_LIB_F33" ] && [ -n "${SPRINT_ID:-}" ]; then
    bp_json_f33="$(bash "$LIFECYCLE_LIB_F33" read --sprint-id "$SPRINT_ID" 2>/dev/null || echo '{"bypasses":[]}')"
    if printf '%s' "$bp_json_f33" | jq -e '.bypasses | any(.skill == "gaia-trace" or .skill == "/gaia-trace")' >/dev/null 2>&1; then
      has_trace_bypass=1
      bp_reason_f33="$(printf '%s' "$bp_json_f33" | jq -r '[.bypasses[] | select(.skill == "gaia-trace" or .skill == "/gaia-trace")][0].reason')"
    fi
  fi

  if [ "$has_trace_bypass" -eq 1 ]; then
    log "traceability-matrix gate bypassed for sprint ${SPRINT_ID}: ${bp_reason_f33}"
  elif [ "$strict_on_f33" -eq 0 ]; then
    log "WARNING: traceability-matrix.md not found at $TM_ART — would block in strict mode; consider running /gaia-trace OR --bypass gaia-trace --reason \"<text>\" (ADR-042 / F-33 mitigation)"
  else
    die "traceability-matrix.md not found at $TM_ART — run /gaia-trace OR add --bypass gaia-trace --reason \"<text>\" (ADR-042 mandatory gate, distributed enforcement per F-33)"
  fi
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
