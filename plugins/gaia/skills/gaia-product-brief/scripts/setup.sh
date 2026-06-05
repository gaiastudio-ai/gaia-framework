#!/usr/bin/env bash
# setup.sh — shared skill setup for gaia-product-brief
#
# Mechanical copy of the shared reference implementation
# (gaia-brainstorm/scripts/setup.sh). Only WORKFLOW_NAME and SCRIPT_NAME
# differ — the body is byte-identical to the reference.
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs
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

SCRIPT_NAME="gaia-product-brief/setup.sh"
WORKFLOW_NAME="create-product-brief"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-product-brief/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
GATE_PREDICATES="$PLUGIN_SCRIPTS_DIR/lib/gate-predicates.sh"
SKILL_MD_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/SKILL.md"

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
# create-product-brief's legacy workflow had a soft dependency on the
# brainstorm artifact, but downstream sibling skills run this shared no-op
# gate pattern. Keep parity with the shared reference — run the file_exists
# gate with zero --file arguments (passing no-op). Story-level prereqs
# (brainstorm/market/domain research) are discovered by the skill body
# itself in Step 1, matching the legacy instructions.xml behaviour.
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" file_exists >/dev/null 2>&1; then
    die "validate-gate.sh pre-start gate failed for $WORKFLOW_NAME"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate (non-fatal)"
fi

# ---------- 2b. Quality gates: pre_start ----------
# Source the shared gate-predicates library and iterate the pre_start
# list declared in this skill's SKILL.md frontmatter. Backward
# compatible: if the block is absent or empty, this is a no-op.
# HALT on first failure to match workflow.xml rule n="10".
#
# The sole pre_start gate is the brainstorm-artifact existence check.
# The legitimate flow where a brief already exists or the operator seeds
# from outside material had no escape hatch. GAIA_SKIP_BRAINSTORM=1
# bypasses the pre_start gates (framework env-var convention, cf. GAIA_YOLO_FLAG)
# and emits a visible audit warning so the bypass is traceable.
if [ -n "${GAIA_SKIP_BRAINSTORM:-}" ]; then
  log "WARNING: GAIA_SKIP_BRAINSTORM set — bypassing pre_start brainstorm gate (operator-asserted brief/source material exists)"
elif [ -f "$GATE_PREDICATES" ]; then
  # shellcheck disable=SC1090
  . "$GATE_PREDICATES"
  if ! _gate_run_pre_start "$SKILL_MD_PATH" "$SCRIPT_NAME: quality-gate"; then
    exit 1
  fi
else
  log "gate-predicates.sh not found at $GATE_PREDICATES — skipping quality gates (non-fatal)"
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
