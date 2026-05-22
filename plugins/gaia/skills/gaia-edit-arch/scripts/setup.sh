#!/usr/bin/env bash
# setup.sh — Cluster 6 architecture skill setup (E28-S46, brief §Cluster 6 / P6-S2)
#
# Mechanical extension of the Cluster 4 reference implementation authored
# under E28-S35 (gaia-brainstorm/scripts/setup.sh). Adds edit-arch-specific
# prereq gates:
#   - architecture.md must exist in planning-artifacts (validate-gate file_exists)
#
# Responsibilities (per brief §Cluster 4):
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

# ---------- 2b. Guard: architecture.md must already exist ----------
# AF-2026-05-21-25 three-tier idiom (mirrors AF-21-12 gaia-edit-prd/setup.sh).
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SKILL_DIR/../../../../.." && pwd)}"
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
