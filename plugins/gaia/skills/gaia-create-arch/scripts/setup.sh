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

# ---------- 0. Parse --bypass / --reason flags (AF-2026-05-24-8 / Test02 F-3) ----------
# Test02 F-3: the threat-model gate error message advertised
# `--bypass gaia-threat-model --reason "<text>"` but setup.sh never parsed
# the flags — so passing them did nothing and the gate still halted. The
# canonical primitive is `bash scripts/lib/lifecycle-overrides.sh append
# --skill --reason --sprint-id` which records the bypass to
# .gaia/state/lifecycle-overrides.yaml. This block parses the advertised
# flags and writes the bypass record before the gate check below runs.
BYPASS_SKILL=""
BYPASS_REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bypass)
      [ $# -ge 2 ] || { printf '%s: --bypass requires a skill name (e.g. gaia-threat-model)\n' "$SCRIPT_NAME" >&2; exit 2; }
      BYPASS_SKILL="$2"; shift 2 ;;
    --reason)
      [ $# -ge 2 ] || { printf '%s: --reason requires a quoted text argument\n' "$SCRIPT_NAME" >&2; exit 2; }
      BYPASS_REASON="$2"; shift 2 ;;
    --help|-h)
      printf 'Usage: %s [--bypass <skill> --reason "<text>"]\n' "$SCRIPT_NAME"
      exit 0 ;;
    -*)
      printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2
      exit 2 ;;
    *)
      shift ;;
  esac
done

# If --bypass was specified, --reason MUST also be specified
if [ -n "$BYPASS_SKILL" ] && [ -z "$BYPASS_REASON" ]; then
  printf '%s: --bypass %s also requires --reason "<text>" (no anonymous bypasses)\n' "$SCRIPT_NAME" "$BYPASS_SKILL" >&2
  exit 2
fi

# Record the bypass via the canonical helper. The helper writes to
# .gaia/state/lifecycle-overrides.yaml (per ADR-120 / E103-S2 contract).
# We do this BEFORE the gate check below so the gate's bypass-lookup
# finds the record.
if [ -n "$BYPASS_SKILL" ]; then
  SCRIPT_DIR_BP="$(cd "$(dirname "$0")" && pwd)"
  LIFECYCLE_LIB_BP="$(cd "$SCRIPT_DIR_BP/../../.." && pwd)/scripts/lib/lifecycle-overrides.sh"
  if [ -f "$LIFECYCLE_LIB_BP" ]; then
    # The lib is sourced-style (defines functions) AND has a `bash $lib append --skill --reason --sprint-id` CLI mode.
    # SPRINT_ID may not yet be resolved (resolve-config runs in §1 below), so try yq for it from the canonical state file.
    BP_SPRINT_ID="${SPRINT_ID:-}"
    if [ -z "$BP_SPRINT_ID" ] && [ -f ".gaia/state/sprint-status.yaml" ] && command -v yq >/dev/null 2>&1; then
      BP_SPRINT_ID="$(yq eval '.sprint_id // ""' .gaia/state/sprint-status.yaml 2>/dev/null || echo "")"
    fi
    if [ -n "$BP_SPRINT_ID" ]; then
      bash "$LIFECYCLE_LIB_BP" append --skill "$BYPASS_SKILL" --reason "$BYPASS_REASON" --sprint-id "$BP_SPRINT_ID" 2>&1 || {
        printf '%s: WARNING: lifecycle-overrides.sh append failed; gate may still halt\n' "$SCRIPT_NAME" >&2
      }
    else
      printf '%s: WARNING: cannot record --bypass without resolvable SPRINT_ID (no .gaia/state/sprint-status.yaml or env SPRINT_ID); gate may still halt\n' "$SCRIPT_NAME" >&2
    fi
  else
    printf '%s: WARNING: lifecycle-overrides.sh not found at %s; --bypass flag is a no-op\n' "$SCRIPT_NAME" "$LIFECYCLE_LIB_BP" >&2
  fi
fi

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
