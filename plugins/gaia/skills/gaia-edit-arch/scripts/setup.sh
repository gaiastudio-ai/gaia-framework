#!/usr/bin/env bash
# setup.sh — architecture skill setup
#
# Mechanical extension of the brainstorm reference implementation
# (gaia-brainstorm/scripts/setup.sh). Adds edit-arch-specific
# prereq gates:
#   - architecture.md must exist in planning-artifacts (validate-gate file_exists)
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (architecture.md existence)
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

SCRIPT_NAME="gaia-edit-arch/setup.sh"
WORKFLOW_NAME="edit-architecture"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-edit-arch/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
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

# Project root resolution: env vars, then resolve-config.sh project_root
# (absolute values only), then walk up from $PWD to the .gaia/config/
# project-config.yaml anchor (stopping at $HOME), then $PWD as last resort.
# Resolved before the design gate so it sees the correct project tree.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-}}}"
if [ -z "$PROJECT_ROOT" ]; then
  _rc_helper="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
  if [ -x "$_rc_helper" ]; then
    _rc_out="$("$_rc_helper" project_root 2>/dev/null || printf '')"
    case "${_rc_out:-}" in
      /*) PROJECT_ROOT="$_rc_out" ;;
    esac
  fi
fi
if [ -z "$PROJECT_ROOT" ]; then
  _walk="$PWD"
  while [ -n "$_walk" ] && [ "$_walk" != "/" ] && [ "$_walk" != "${HOME:-}" ]; do
    if [ -f "${_walk}/.gaia/config/project-config.yaml" ]; then
      PROJECT_ROOT="$_walk"
      break
    fi
    _walk="$(dirname "$_walk")"
  done
fi
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
export PROJECT_ROOT
printf 'project_root=%s\n' "$PROJECT_ROOT" >&2

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
# edit-architecture requires an existing architecture.md in planning-artifacts.
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

# ---------- 2b. Guard: architecture.md must already exist ----------
# PROJECT_ROOT was resolved at script entry (before the design gate).
if [ -z "${ARCH_PATH:-}" ]; then
  if [ -f "$PROJECT_ROOT/docs/planning-artifacts/architecture.md" ] && [ ! -d "$PROJECT_ROOT/.gaia/artifacts/planning-artifacts" ]; then
    ARCH_PATH="$PROJECT_ROOT/docs/planning-artifacts/architecture.md"
  else
    ARCH_PATH="$PROJECT_ROOT/.gaia/artifacts/planning-artifacts/architecture.md"
  fi
fi

if [ ! -f "$ARCH_PATH" ]; then
  log "architecture.md not found at $ARCH_PATH (canonical .gaia/artifacts/planning-artifacts/architecture.md or legacy docs/planning-artifacts/architecture.md) — edit-arch requires an existing architecture (non-fatal in setup)"
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

log "setup complete for $WORKFLOW_NAME"
exit 0
