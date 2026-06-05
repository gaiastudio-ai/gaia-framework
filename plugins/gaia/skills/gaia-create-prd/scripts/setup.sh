#!/usr/bin/env bash
# setup.sh — planning skill setup for create-prd
#
# Extension of the brainstorm reference implementation
# (gaia-brainstorm/scripts/setup.sh). Adds create-prd-specific prereq gates:
#   - product-brief must exist (validate-gate file_exists)
#   - prd-template.md must exist in the skill directory or custom/templates/
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (product-brief, prd-template)
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

SCRIPT_NAME="gaia-create-prd/setup.sh"
WORKFLOW_NAME="create-prd"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-create-prd/scripts/setup.sh → ../../../scripts
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
# create-prd requires a product-brief to exist. The skill body validates
# the exact path from the user argument; here we validate that the
# planning-artifacts directory exists at minimum.
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" file_exists >/dev/null 2>&1; then
    die "validate-gate.sh pre-start gate failed for $WORKFLOW_NAME"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate (non-fatal)"
fi

# ---------- 2b. Guard: prd-template.md must be present ----------
# Check skill-local copy first, then custom/templates/ override. If neither
# exists, fail fast.
TEMPLATE_LOCAL="$SKILL_DIR/prd-template.md"
# Prefer CLAUDE_PROJECT_ROOT (the framework-standard harness var) and
# GAIA_PROJECT_ROOT (project-specific) BEFORE the $SKILL_DIR/../../../../..
# walk-up. On a marketplace/cache-installed plugin
# (~/.claude/plugins/cache/<mp>/gaia/<ver>/skills/<skill>/scripts/), walking
# 5 levels up lands in `~/.claude/plugins/cache` — NOT the user's project —
# and every subsequent .gaia/ artifact lookup misses. Honoring the harness-
# provided env vars first restores the project anchor that callers actually
# rely on. The walk-up remains as the final fallback for in-source-tree dev
# (gaia-framework/ checkout) where neither env var is set.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$(cd "$SKILL_DIR/../../../../.." && pwd)}}}"
TEMPLATE_CUSTOM="$PROJECT_ROOT/custom/templates/prd-template.md"

if [ ! -s "$TEMPLATE_LOCAL" ] && [ ! -s "$TEMPLATE_CUSTOM" ]; then
  die "prd-template.md missing — not found in skill directory ($TEMPLATE_LOCAL) or custom/templates/ ($TEMPLATE_CUSTOM). Cannot proceed."
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
