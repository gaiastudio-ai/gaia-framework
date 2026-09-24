#!/usr/bin/env bash
# setup.sh — adversarial review skill setup
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (no-op, parity with siblings)
#   2a. Quality gates: pre_start (design_approved gate)
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

SCRIPT_NAME="gaia-adversarial/setup.sh"
WORKFLOW_NAME="adversarial-review"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-adversarial/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
GATE_PREDICATES="$PLUGIN_SCRIPTS_DIR/lib/gate-predicates.sh"
SKILL_MD_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/SKILL.md"

# ---------- 0. Parse --force-design flags ----------
PARSE_FORCE_DESIGN="$PLUGIN_SCRIPTS_DIR/lib/parse-force-design.sh"
# shellcheck disable=SC1090
. "$PARSE_FORCE_DESIGN"
_parse_force_design "$@"; set -- "${_PFD_REMAINING[@]+"${_PFD_REMAINING[@]}"}"


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
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" file_exists >/dev/null 2>&1; then
    die "validate-gate.sh pre-start gate failed for $WORKFLOW_NAME"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate (non-fatal)"
fi

# ---------- 2a. Quality gates: pre_start ----------
if [ -f "$GATE_PREDICATES" ]; then
  # shellcheck disable=SC1090
  . "$GATE_PREDICATES"
  _gate_run_pre_start "$SKILL_MD_PATH" "$SCRIPT_NAME: quality-gate" || exit 1
else
  die "gate-predicates.sh not found at $GATE_PREDICATES — cannot evaluate required quality gates"
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
