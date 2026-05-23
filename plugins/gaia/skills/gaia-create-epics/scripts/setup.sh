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
# AF-2026-05-22-6 Bug-4: resolve the actual test-plan path via the same
# 4-path fallback that validate-gate.sh test_plan_exists honors (flat /
# strategy/test-plan.md / strategy/test-strategy.md / test-plan/index.md).
# Previously this script independently checked only $TEST_ARTIFACTS/test-plan.md
# (the flat path), so /gaia-test-strategy --plan (which writes
# strategy/test-strategy.md) caused a false-halt with "exists but empty"
# even though the artifact existed under a different accepted path.
TEST_PLAN_PATH=""
for candidate in \
  "$TEST_ARTIFACTS/test-plan.md" \
  "$TEST_ARTIFACTS/strategy/test-plan.md" \
  "$TEST_ARTIFACTS/strategy/test-strategy.md" \
  "$TEST_ARTIFACTS/test-plan/index.md"; do
  if [ -s "$candidate" ]; then
    TEST_PLAN_PATH="$candidate"
    break
  fi
done

if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" test_plan_exists 2>&1; then
    die "HALT: test-plan.md not found — run /gaia-test-strategy --plan first to create it (ADR-042 enforced gate). Accepted paths: $TEST_ARTIFACTS/test-plan.md OR $TEST_ARTIFACTS/strategy/test-plan.md OR $TEST_ARTIFACTS/strategy/test-strategy.md OR $TEST_ARTIFACTS/test-plan/index.md"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate (non-fatal)"
fi

# ---------- 2b. Guard: resolved test-plan must be non-empty (AC-EC1) ----------
# validate-gate.sh checks non-empty too, but emit a clearer error if the
# resolver chose a path that turned out empty (race or odd FS state).
if [ -z "$TEST_PLAN_PATH" ] || [ ! -s "$TEST_PLAN_PATH" ]; then
  die "HALT: no non-empty test-plan artifact found under $TEST_ARTIFACTS/ (checked test-plan.md, strategy/test-plan.md, strategy/test-strategy.md, test-plan/index.md) — run /gaia-test-strategy --plan to populate it (ADR-042 enforced gate)"
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
