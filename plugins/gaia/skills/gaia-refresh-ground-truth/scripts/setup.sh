#!/usr/bin/env bash
# setup.sh — gaia-refresh-ground-truth skill setup (E28-S79)
#
# Follows the shared setup.sh pattern from E28-S17.
# Validates that the target sidecar directory is accessible.
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (sidecar directory writable)
#   3. Load the checkpoint state for this workflow
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution, gate validation, or checkpoint load failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-refresh-ground-truth/setup.sh"
WORKFLOW_NAME="gaia-refresh-ground-truth"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="${PLUGIN_SCRIPTS_DIR_OVERRIDE:-$(cd "$SCRIPT_DIR/../../../scripts" && pwd)}"

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

# ---------- 2. Validate sidecar directory accessible ----------
# Inline writability check. Previously delegated to validate-gate.sh dir_writable,
# but that gate type is not in validate-gate.sh's registry (which scopes to
# artifact-existence gates only), so the call silently fell through and the
# writability precondition was skipped on every refresh.
# AF-2026-05-27-3 (ADR-111): default to canonical .gaia/memory (legacy _memory removed).
SIDECAR_DIR="${memory_path:-./.gaia/memory}/validator-sidecar"
if [ -d "$SIDECAR_DIR" ] && [ ! -w "$SIDECAR_DIR" ]; then
  log "warning: sidecar directory may not be writable: $SIDECAR_DIR (non-fatal)"
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
