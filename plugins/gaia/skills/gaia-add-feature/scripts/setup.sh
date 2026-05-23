#!/usr/bin/env bash
# setup.sh — add-feature skill setup (E28-S57)
#
# Mechanical extension of the Cluster 4 reference implementation authored
# under E28-S35 (gaia-brainstorm/scripts/setup.sh). Adds add-feature-specific
# prereq gates:
#   - prd.md must exist (PRD is always needed for feature triage)
#   - epics-and-stories.md must exist
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (prd.md, epics-and-stories.md)
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

SCRIPT_NAME="gaia-add-feature/setup.sh"
WORKFLOW_NAME="add-feature"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-add-feature/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. CLI surface (E89-S1, FR-AFE-1) ----------
# Optional flags consumed by SKILL.md Step 1c re-invocation:
#   --classification <patch|enhancement|feature>   default: enhancement
#   --feature-id <AF-{date}-{N}>                    default: empty string
# Unknown flags die non-zero. The flag-parsing loop sits BEFORE the
# validate-gate.sh invocations so CLASSIFICATION and FEATURE_ID are
# available when the test-plan / traceability gates fire (AC1..AC4).
CLASSIFICATION="enhancement"
FEATURE_ID=""
STEP_8_MODE=""  # empty = auto-derive from YOLO state (E89-S2 AC2 default)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --classification)
      [[ $# -ge 2 ]] || die "missing value for --classification"
      CLASSIFICATION="$2"
      case "$CLASSIFICATION" in
        patch|enhancement|feature) ;;
        *) die "invalid classification: $CLASSIFICATION (must be patch|enhancement|feature)" ;;
      esac
      shift 2
      ;;
    --classification=*)
      CLASSIFICATION="${1#*=}"
      case "$CLASSIFICATION" in
        patch|enhancement|feature) ;;
        *) die "invalid classification: $CLASSIFICATION (must be patch|enhancement|feature)" ;;
      esac
      shift
      ;;
    --feature-id)
      [[ $# -ge 2 ]] || die "missing value for --feature-id"
      FEATURE_ID="$2"
      shift 2
      ;;
    --feature-id=*)
      FEATURE_ID="${1#*=}"
      shift
      ;;
    --step-8-mode)
      [[ $# -ge 2 ]] || die "missing value for --step-8-mode"
      STEP_8_MODE="$2"
      case "$STEP_8_MODE" in
        inline-dispatch|deferred-seed-brief) ;;
        *) die "gaia-add-feature: invalid --step-8-mode value (expected inline-dispatch or deferred-seed-brief, got: $STEP_8_MODE)" ;;
      esac
      shift 2
      ;;
    --step-8-mode=*)
      STEP_8_MODE="${1#*=}"
      case "$STEP_8_MODE" in
        inline-dispatch|deferred-seed-brief) ;;
        *) die "gaia-add-feature: invalid --step-8-mode value (expected inline-dispatch or deferred-seed-brief, got: $STEP_8_MODE)" ;;
      esac
      shift
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

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

# ---------- 2. Validate gates ----------
# E96-S7 partial-4c: smart-fallback
if [ -z "${PLANNING_ARTIFACTS:-}" ]; then
  if [ -d ".gaia/artifacts/planning-artifacts" ]; then
    PLANNING_ARTIFACTS=".gaia/artifacts/planning-artifacts"
  else
    PLANNING_ARTIFACTS="docs/planning-artifacts"
  fi
fi
PLANNING="$PLANNING_ARTIFACTS"
PRD_PATH="$PLANNING/prd.md"
EPICS_PATH="$PLANNING/epics-and-stories.md"

if [ -z "${TEST_ARTIFACTS:-}" ]; then
  if [ -d ".gaia/artifacts/test-artifacts" ]; then
    TEST_ARTIFACTS=".gaia/artifacts/test-artifacts"
  else
    TEST_ARTIFACTS="docs/test-artifacts"
  fi
fi
TEST_ARTIFACTS_DIR="$TEST_ARTIFACTS"

if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" prd_exists 2>&1; then
    die "HALT: prd.md not found at $PRD_PATH — run /gaia-create-prd first"
  fi
  if ! "$VALIDATE_GATE" epics_and_stories_exists 2>&1; then
    die "HALT: epics-and-stories.md not found at $EPICS_PATH — run /gaia-create-epics first"
  fi
  # E89-S1 (FR-AFE-1): test-plan + traceability gates fire ONLY under
  # enhancement / feature classifications. Patch classifications skip
  # these gates (matches the existing cascade-matrix behaviour).
  if [ "$CLASSIFICATION" = "enhancement" ] || [ "$CLASSIFICATION" = "feature" ]; then
    if ! "$VALIDATE_GATE" test_plan_exists 2>&1; then
      die "HALT: test-plan.md is missing — run /gaia-test-design first, then re-invoke /gaia-add-feature $FEATURE_ID"
    fi
    if ! "$VALIDATE_GATE" traceability_exists 2>&1; then
      die "HALT: traceability-matrix.md is missing — run /gaia-trace first, then re-invoke /gaia-add-feature $FEATURE_ID"
    fi
  fi
else
  # Fallback: manual checks when validate-gate.sh is not available
  if [ ! -s "$PRD_PATH" ]; then
    die "HALT: prd.md not found or empty at $PRD_PATH — run /gaia-create-prd first"
  fi
  if [ ! -s "$EPICS_PATH" ]; then
    die "HALT: epics-and-stories.md not found or empty at $EPICS_PATH — run /gaia-create-epics first"
  fi
  # E89-S1 fallback mirror: same classification-conditional behaviour.
  if [ "$CLASSIFICATION" = "enhancement" ] || [ "$CLASSIFICATION" = "feature" ]; then
    # AF-2026-05-22-6 Bug-20: also accept strategy/test-strategy.md (the actual
    # output of /gaia-test-strategy --plan) and the sharded test-plan/index.md
    # form. Mirrors the 4-path fallback in validate-gate.sh test_plan_exists.
    if [ ! -s "$TEST_ARTIFACTS_DIR/test-plan.md" ] \
       && [ ! -s "$TEST_ARTIFACTS_DIR/strategy/test-plan.md" ] \
       && [ ! -s "$TEST_ARTIFACTS_DIR/strategy/test-strategy.md" ] \
       && [ ! -s "$TEST_ARTIFACTS_DIR/test-plan/index.md" ]; then
      die "HALT: test-plan.md is missing — run /gaia-test-strategy --plan first, then re-invoke /gaia-add-feature $FEATURE_ID"
    fi
    if [ ! -s "$TEST_ARTIFACTS_DIR/traceability-matrix.md" ] && [ ! -s "$TEST_ARTIFACTS_DIR/strategy/traceability-matrix.md" ]; then
      die "HALT: traceability-matrix.md is missing — run /gaia-trace first, then re-invoke /gaia-add-feature $FEATURE_ID"
    fi
  fi
  log "validate-gate.sh not found at $VALIDATE_GATE — used manual checks (non-fatal)"
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
