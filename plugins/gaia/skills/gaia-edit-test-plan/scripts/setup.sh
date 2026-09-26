#!/usr/bin/env bash
# setup.sh — gaia-edit-test-plan skill setup
#
# Mechanical extension of the gaia-code-review/scripts/setup.sh reference
# implementation. Adds edit-test-plan-specific prereq gates:
#   - test-plan.md must exist in test-artifacts (validate-gate file_exists)
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (test-plan.md existence)
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

SCRIPT_NAME="gaia-edit-test-plan/setup.sh"
WORKFLOW_NAME="edit-test-plan"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-edit-test-plan/scripts/setup.sh → ../../../scripts
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
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" file_exists >/dev/null 2>&1; then
    die "validate-gate.sh pre-start gate failed for $WORKFLOW_NAME"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate (non-fatal)"
fi

# ---------- 2b. Guard: test-plan.md must already exist ----------
# Three-tier path resolution:
#   Tier 1 — TEST_PLAN_PATH env-var override wins when set.
#   Tier 2 — positive legacy evidence (legacy file exists AND canonical
#            dir does NOT) → use legacy docs/test-artifacts/test-plan.md.
#   Tier 3 — canonical default: .gaia/artifacts/test-artifacts/test-plan.md.
# Project root resolution: env vars (PROJECT_ROOT, CLAUDE_PROJECT_ROOT,
# GAIA_PROJECT_ROOT), then walk up from $PWD to the .gaia/config/
# project-config.yaml anchor (stopping at $HOME), then $PWD as last resort.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-}}}"
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
if [ -z "${TEST_PLAN_PATH:-}" ]; then
  if [ -f "$PROJECT_ROOT/docs/test-artifacts/test-plan.md" ] && [ ! -d "$PROJECT_ROOT/.gaia/artifacts/test-artifacts" ]; then
    TEST_PLAN_PATH="$PROJECT_ROOT/docs/test-artifacts/test-plan.md"
  else
    TEST_PLAN_PATH="$PROJECT_ROOT/.gaia/artifacts/test-artifacts/test-plan.md"
  fi
fi

if [ ! -f "$TEST_PLAN_PATH" ]; then
  log "test-plan.md not found at $TEST_PLAN_PATH (canonical .gaia/artifacts/test-artifacts/test-plan.md or legacy docs/test-artifacts/test-plan.md) — edit-test-plan requires an existing test plan (non-fatal in setup)"
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
