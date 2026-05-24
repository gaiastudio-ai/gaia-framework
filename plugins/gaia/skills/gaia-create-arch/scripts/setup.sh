#!/usr/bin/env bash
# setup.sh — Cluster 6 architecture skill setup (E28-S45, brief §Cluster 6 / P6-S1)
#
# Mechanical extension of the Cluster 4 reference implementation authored
# under E28-S35 (gaia-brainstorm/scripts/setup.sh). Adds create-arch-specific
# prereq gates:
#   - prd.md must exist (validate-gate file_exists)
#   - architecture-template.md must exist in the skill directory or custom/templates/
#
# Responsibilities (per brief §Cluster 4):
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (prd, architecture-template)
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

SCRIPT_NAME="gaia-create-arch/setup.sh"
WORKFLOW_NAME="create-architecture"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-create-arch/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
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

# ---------- 2. Validate gate (prereqs) ----------
# create-architecture requires a PRD to exist. The skill body validates
# the exact path; here we validate that the planning-artifacts directory
# exists at minimum.
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" file_exists >/dev/null 2>&1; then
    die "validate-gate.sh pre-start gate failed for $WORKFLOW_NAME"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate (non-fatal)"
fi

# ---------- 2b. Guard: architecture-template.md must be present ----------
# Check skill-local copy first, then custom/templates/ override. If neither
# exists, fail fast.
TEMPLATE_LOCAL="$SKILL_DIR/architecture-template.md"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SKILL_DIR/../../../../.." && pwd)}"
TEMPLATE_CUSTOM="$PROJECT_ROOT/custom/templates/architecture-template.md"

if [ ! -s "$TEMPLATE_LOCAL" ] && [ ! -s "$TEMPLATE_CUSTOM" ]; then
  die "architecture-template.md missing — not found in skill directory ($TEMPLATE_LOCAL) or custom/templates/ ($TEMPLATE_CUSTOM). Cannot proceed."
fi

# ---------- 3. Load checkpoint state ----------
if [ -x "$CHECKPOINT" ]; then
  # `checkpoint.sh read` exits 2 when no checkpoint exists (fresh run) —
  # that is a valid state for the first invocation of a skill. Any other
  # non-zero exit indicates a real error.
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

# ---------- 5. Conditional threat-model gate (ADR-120 / E103-S6) ----------
# When `compliance.ui_present: true`, require either a threat-model artifact
# OR a recorded `gaia-threat-model` bypass for the active sprint. When
# `compliance.ui_present` is false / absent, the gate is a no-op.

SCRIPT_DIR_S6="$(cd "$(dirname "$0")" && pwd)"
LIFECYCLE_LIB_S6="$(cd "$SCRIPT_DIR_S6/../../.." && pwd)/scripts/lib/lifecycle-overrides.sh"
STRICT_HELPER_S6="$(cd "$SCRIPT_DIR_S6/../../.." && pwd)/scripts/lib/lifecycle-strict-mode.sh"

# Read compliance.ui_present from project-config.yaml.
PROJECT_CONFIG_S6="${PROJECT_CONFIG:-.gaia/config/project-config.yaml}"
ui_present="false"
if [ -f "$PROJECT_CONFIG_S6" ] && command -v yq >/dev/null 2>&1; then
  ui_present="$(yq eval '.compliance.ui_present // false' "$PROJECT_CONFIG_S6" 2>/dev/null || echo "false")"
fi

if [ "$ui_present" != "true" ]; then
  log "threat-model gate skipped: compliance.ui_present is false (or absent)"
else
  # Strict-mode resolution.
  strict_on=1
  if [ -x "$STRICT_HELPER_S6" ]; then
    if "$STRICT_HELPER_S6" lifecycle_strict_mode_enabled >/dev/null 2>&1; then
      strict_on=1
    else
      strict_on=0
    fi
  fi

  TM_ART="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/threat-model.md"
  if [ -f "$TM_ART" ] && [ -s "$TM_ART" ]; then
    log "threat-model artifact present: $TM_ART"
  else
    # Check for bypass.
    has_tm_bypass=0
    bp_reason=""
    if [ -f "$LIFECYCLE_LIB_S6" ] && [ -n "${SPRINT_ID:-}" ]; then
      bp_json="$(bash "$LIFECYCLE_LIB_S6" read --sprint-id "$SPRINT_ID" 2>/dev/null || echo '{"bypasses":[]}')"
      if printf '%s' "$bp_json" | jq -e '.bypasses | any(.skill == "gaia-threat-model" or .skill == "/gaia-threat-model")' >/dev/null 2>&1; then
        has_tm_bypass=1
        bp_reason="$(printf '%s' "$bp_json" | jq -r '[.bypasses[] | select(.skill == "gaia-threat-model" or .skill == "/gaia-threat-model")][0].reason')"
      fi
    fi
    if [ "$has_tm_bypass" -eq 1 ]; then
      log "threat-model gate bypassed: ${bp_reason}"
    elif [ "$strict_on" -eq 0 ]; then
      log "WARNING: compliance.ui_present=true but no threat-model.md found — would block in strict mode; consider --bypass gaia-threat-model --reason \"<text>\""
    else
      die "compliance.ui_present=true but no threat-model.md found; run /gaia-threat-model OR add --bypass gaia-threat-model --reason \"<text>\""
    fi
  fi
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
