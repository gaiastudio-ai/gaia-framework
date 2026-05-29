#!/usr/bin/env bash
# setup.sh — Cluster 11 gaia-edit-test-plan skill setup (E28-S87)
#
# Mechanical extension of the Cluster 9 reference implementation authored
# under E28-S66 (gaia-code-review/scripts/setup.sh). Adds edit-test-plan-
# specific prereq gates:
#   - test-plan.md must exist in test-artifacts (validate-gate file_exists)
#
# Responsibilities (per brief Cluster 11):
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
# AF-2026-05-21-19 three-tier path resolution (mirrors AF-21-12/-14 flat elif chain):
#   Tier 1 — TEST_PLAN_PATH env-var override wins when set.
#   Tier 2 — positive pre-ADR-111 evidence (legacy file exists AND canonical
#            dir does NOT) → use legacy docs/test-artifacts/test-plan.md.
#   Tier 3 — canonical default: .gaia/artifacts/test-artifacts/test-plan.md per ADR-111.
# AF-2026-05-29-2 / Test09 F-20: prefer CLAUDE_PROJECT_ROOT (the framework-
# standard harness var) and GAIA_PROJECT_ROOT (project-specific) BEFORE the
# $SKILL_DIR/../../../../.. walk-up. On a marketplace/cache-installed plugin
# (~/.claude/plugins/cache/<mp>/gaia/<ver>/skills/<skill>/scripts/), walking
# 5 levels up lands in `~/.claude/plugins/cache` — NOT the user's project —
# and every subsequent .gaia/ artifact lookup misses. Honoring the harness-
# provided env vars first restores the project anchor that callers actually
# rely on. The walk-up remains as the final fallback for in-source-tree dev
# (gaia-public/ checkout) where neither env var is set.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$(cd "$SKILL_DIR/../../../../.." && pwd)}}}"
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
