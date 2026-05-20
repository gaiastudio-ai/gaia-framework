#!/usr/bin/env bash
# setup.sh — Cluster 6 create-epics skill setup (E28-S47, brief §Cluster 6 / P6-S3)
#
# Mechanical extension of the Cluster 4 reference implementation authored
# under E28-S35 (gaia-brainstorm/scripts/setup.sh). Adds create-epics-specific
# prereq gates:
#   - test-plan.md must exist and be non-empty (validate-gate test_plan_exists)
#     per CLAUDE.md "Testing integration gates (enforced)" — ADR-042
#
# Responsibilities (per brief §Cluster 4):
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (test-plan.md — enforced, not advisory)
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

SCRIPT_NAME="gaia-create-epics/setup.sh"
WORKFLOW_NAME="create-epics-stories"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-create-epics/scripts/setup.sh → ../../../scripts
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

# ---------- 2. Validate gate (test-plan.md required — enforced, not advisory) ----------
# CLAUDE.md "Testing integration gates (enforced)":
#   create-epics-stories requires test-plan.md
# ADR-042: quality gates are enforced — validate-gate.sh MUST exit non-zero
# when the prerequisite is missing; a warning is not sufficient.
# Remediation: run /gaia-test-design to create test-plan.md
# E96-S7 partial-4c: smart-fallback
if [ -z "${TEST_ARTIFACTS:-}" ]; then
  if [ -d ".gaia/artifacts/test-artifacts" ]; then
    TEST_ARTIFACTS=".gaia/artifacts/test-artifacts"
  else
    TEST_ARTIFACTS="docs/test-artifacts"
  fi
fi
TEST_PLAN_PATH="$TEST_ARTIFACTS/test-plan.md"

if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" test_plan_exists 2>&1; then
    die "HALT: test-plan.md not found at $TEST_PLAN_PATH — run /gaia-test-design first to create it (ADR-042 enforced gate)"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate (non-fatal)"
fi

# ---------- 2b. Guard: test-plan.md must be non-empty (AC-EC1) ----------
# The shared validate-gate.sh checks file existence only. Per AC-EC1 and
# ADR-042, a zero-byte file is treated as missing — existence alone is
# not sufficient.
if [ ! -s "$TEST_PLAN_PATH" ]; then
  die "HALT: test-plan.md exists but is empty (zero-byte) at $TEST_PLAN_PATH — run /gaia-test-design to populate it (ADR-042 enforced gate)"
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
