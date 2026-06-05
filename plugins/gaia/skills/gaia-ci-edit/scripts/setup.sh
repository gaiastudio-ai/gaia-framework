#!/usr/bin/env bash
# setup.sh — gaia-ci-edit skill setup
#
# Mechanical extension of the gaia-code-review/scripts/setup.sh reference
# implementation. Only WORKFLOW_NAME and SCRIPT_NAME differ — the body
# follows the shared pattern.
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh prereq check
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

SCRIPT_NAME="gaia-ci-edit/setup.sh"
WORKFLOW_NAME="ci-edit"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-ci-edit/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# ---------- 2. Validate gate — dependency check ----------
[ -x "$VALIDATE_GATE" ] || die "validate-gate.sh not found or not executable at $VALIDATE_GATE — validate-gate dependency must be installed first"

# ---------- 2b. Record "had prior setup" marker ----------
#
# This block introduces a conditional guard on the `ci_setup_exists` post-check
# in finalize.sh. The guard uses a runtime marker file:
#
#   ${PROJECT_ROOT:-$PWD}/.gaia/run-state/ci-edit-had-prior-setup
#
# setup.sh probes for .gaia/artifacts/test-artifacts/ci-setup.md at invocation time.
# If it exists, a prior CI setup is in place and an edit is genuinely
# editing an existing file — in that case finalize.sh MUST still invoke
# ci_setup_exists as a regression guard (catches the "edit erased the
# file" bug class). If the setup file is absent at invocation time,
# no marker is written and finalize.sh skips the gate entirely
# (fresh-fixture runs exit 0 cleanly).
#
# The marker is plain-filesystem state, not config: it describes "what the
# edit observed at invocation" rather than "how the skill is configured."
# Cleanup is finalize.sh's responsibility — see that script for the
# companion logic. Error-path cleanup is bounded by the TEST_ARTIFACTS
# resolution below and the run-state directory being per-project, so a
# stale marker at worst causes the next edit run to treat an absent
# file as "had prior setup" — which is the SAFER failure mode (gate runs,
# catches the missing file, exits non-zero).

# Smart-fallback for TEST_ARTIFACTS resolution:
if [ -z "${TEST_ARTIFACTS:-}" ]; then
  if [ -d ".gaia/artifacts/test-artifacts" ]; then
    TEST_ARTIFACTS=".gaia/artifacts/test-artifacts"
  else
    TEST_ARTIFACTS="docs/test-artifacts"
  fi
fi
TEST_ARTIFACTS_DIR="$TEST_ARTIFACTS"
CI_SETUP_FILE="$TEST_ARTIFACTS_DIR/ci-setup.md"
RUN_STATE_DIR="${PROJECT_ROOT:-$PWD}/.gaia/run-state"
HAD_PRIOR_SETUP_MARKER="$RUN_STATE_DIR/ci-edit-had-prior-setup"

if [ -f "$CI_SETUP_FILE" ]; then
  if ! mkdir -p "$RUN_STATE_DIR" 2>/dev/null; then
    log "could not create run-state dir at $RUN_STATE_DIR — continuing without marker (finalize will skip the regression guard)"
  else
    : > "$HAD_PRIOR_SETUP_MARKER"
    log "recorded had_prior_setup marker at $HAD_PRIOR_SETUP_MARKER"
  fi
else
  # Fresh fixture or first-ever run — make sure any stale marker from a
  # previous interrupted run is cleared so finalize.sh does not
  # mistakenly run the regression guard against an absent file.
  if [ -f "$HAD_PRIOR_SETUP_MARKER" ]; then
    rm -f "$HAD_PRIOR_SETUP_MARKER" 2>/dev/null || true
    log "cleared stale had_prior_setup marker at $HAD_PRIOR_SETUP_MARKER (no prior ci-setup.md observed)"
  fi
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
