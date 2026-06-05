#!/usr/bin/env bash
# setup.sh — gaia-brownfield skill setup
#
# Mechanical extension of the gaia-code-review / gaia-nfr reference implementation
# (gaia-code-review/scripts/setup.sh, gaia-nfr/scripts/setup.sh). Only
# WORKFLOW_NAME and SCRIPT_NAME differ — the body follows the shared pattern.
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (no specific prereqs for brownfield)
#   3. Load the checkpoint state for this workflow
#
# Fail-fast semantics: if any foundation script is missing or
# non-executable, this setup aborts with a clear message identifying the
# missing path — no partial scan output will be written.
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

SCRIPT_NAME="gaia-brownfield/setup.sh"
WORKFLOW_NAME="brownfield-onboarding"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-brownfield/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Resolve config ----------
# brownfield is THE onboarding command for projects with NO
# .gaia/config/project-config.yaml yet — Phase 1 step 5a auto-drafts the
# config via detect-signals.sh. Previously the resolve-config.sh non-zero exit
# was treated as fatal, so the command that should CREATE the config refused to
# start without one (chicken-and-egg, the user has no way to bootstrap a
# greenfield project that doesn't already have a config). Detect the
# "no config path" condition specifically and degrade to a fresh-project mode —
# the skill body's Phase 1 will auto-draft a config before any downstream gate
# fires. Other resolve-config failures (malformed yaml, schema rejection on an
# EXISTING config) still die.
[ -x "$RESOLVE_CONFIG" ] || die "resolve-config.sh not found or not executable at $RESOLVE_CONFIG"
if ! config_output=$("$RESOLVE_CONFIG" 2>&1); then
  if printf '%s' "$config_output" | grep -q 'no config path'; then
    log "no project-config.yaml found — entering fresh-project onboarding mode (Phase 1 will auto-draft via detect-signals.sh)"
    log "this is the documented entry point for brownfield; no config is required before Phase 1"
    export GAIA_BROWNFIELD_FRESH_PROJECT=1
    # Seed safe defaults the skill body needs before Phase 1 produces the real config.
    PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-${PROJECT_ROOT:-$PWD}}}"
    PROJECT_PATH="$PROJECT_ROOT"
    PLANNING_ARTIFACTS="$PROJECT_ROOT/.gaia/artifacts/planning-artifacts"
    TEST_ARTIFACTS="$PROJECT_ROOT/.gaia/artifacts/test-artifacts"
    IMPLEMENTATION_ARTIFACTS="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
    CREATIVE_ARTIFACTS="$PROJECT_ROOT/.gaia/artifacts/creative-artifacts"
    MEMORY_PATH="$PROJECT_ROOT/.gaia/memory"
    CHECKPOINT_PATH="$MEMORY_PATH/checkpoints"
    export PROJECT_ROOT PROJECT_PATH PLANNING_ARTIFACTS TEST_ARTIFACTS IMPLEMENTATION_ARTIFACTS CREATIVE_ARTIFACTS MEMORY_PATH CHECKPOINT_PATH
    # Also seed the artifact tree (mkdir -p is idempotent) so phase-1+ subagents
    # can write without hitting "no such directory" — brownfield's artifact-write
    # contract assumes the tree exists.
    mkdir -p "$PLANNING_ARTIFACTS" "$TEST_ARTIFACTS" "$IMPLEMENTATION_ARTIFACTS" "$CREATIVE_ARTIFACTS" "$CHECKPOINT_PATH" "$MEMORY_PATH"
  else
    log "resolve-config.sh failed:"
    printf '%s\n' "$config_output" >&2
    exit 1
  fi
else
  while IFS= read -r line; do
    case "$line" in
      [A-Z_]*=*) eval "export $line" ;;
    esac
  done <<<"$config_output"
fi

# ---------- 2. Validate gate ----------
# No specific prereq gate for brownfield onboarding. The three post-complete
# gates (nfr_assessment_exists, performance_test_plan_exists, conditional
# test_environment_yaml_required_when_infra_detected) run at finalize time.

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
