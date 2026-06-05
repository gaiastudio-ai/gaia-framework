#!/usr/bin/env bash
# setup.sh — readiness-check skill setup
#
# Mechanical extension of the brainstorm reference implementation
# (gaia-brainstorm/scripts/setup.sh). Adds readiness-check-specific
# prereq gates:
#   - traceability-matrix.md must exist (validate-gate traceability_exists)
#   - ci-setup.md must exist (validate-gate ci_setup_exists)
#
# Both gates are MANDATORY — there is no "single gate" fallback,
# no env-var bypass, and no flag to make either gate optional. Partial-pass
# is a bug.
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for both prereqs (traceability + ci-setup)
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

SCRIPT_NAME="gaia-readiness-check/setup.sh"
WORKFLOW_NAME="implementation-readiness"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-readiness-check/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Allow override for testing
if [ -n "${PLUGIN_SCRIPTS_DIR:-}" ]; then
  : # use the override
else
  PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"
fi

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Resolve config ----------
if [ -x "$RESOLVE_CONFIG" ]; then
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
else
  log "resolve-config.sh not found at $RESOLVE_CONFIG — using environment defaults"
fi

# ---------- 2. Validate gates (prereqs) — mandatory gates ----------
# The ci-setup.md gate is unconditional by default, but /gaia-init accepts
# `ci_platform.provider: none` as a valid config for projects that
# deliberately skip CI. Those projects could not run /gaia-readiness-check
# at all. Fix: make the ci_setup_exists gate conditional on
# `ci_platform.provider != none`. When `none`, only the traceability gate fires.
NEEDS_CI_GATE=1
PROJECT_CONFIG_PATH="${PROJECT_CONFIG:-.gaia/config/project-config.yaml}"
if [ -f "$PROJECT_CONFIG_PATH" ] && command -v yq >/dev/null 2>&1; then
  ci_provider="$(yq eval '.ci_platform.provider // .ci_cd.provider // ""' "$PROJECT_CONFIG_PATH" 2>/dev/null || echo "")"
  if [ "$ci_provider" = "none" ]; then
    NEEDS_CI_GATE=0
    log "ci-setup.md gate skipped (ci_platform.provider=none — no-CI project shape)"
  fi
fi

if [ -x "$VALIDATE_GATE" ]; then
  if [ "$NEEDS_CI_GATE" -eq 1 ]; then
    GATE_LIST="traceability_exists,ci_setup_exists"
    GATE_REMEDIATION="Run /gaia-trace and/or /gaia-ci-setup to generate the missing artifact(s)."
  else
    GATE_LIST="traceability_exists"
    GATE_REMEDIATION="Run /gaia-trace to generate the missing artifact."
  fi
  if ! "$VALIDATE_GATE" --multi "$GATE_LIST" 2>&1; then
    die "Quality gate failed for $WORKFLOW_NAME — required artifact(s) missing. $GATE_REMEDIATION"
  fi
else
  die "validate-gate.sh not found at $VALIDATE_GATE — cannot enforce mandatory gates"
fi

# ---------- 2b. Guard: traceability-matrix.md must be non-empty ----------
# The shared validate-gate.sh checks file existence only (-f). A zero-byte
# file is treated as missing — existence alone is not sufficient. This
# mirrors the create-epics pattern.
# TEST_ARTIFACTS may be unbound after resolve-config.sh when the script
# runs without a fully-hydrated config (e.g., interactive call without
# --plan output). Default it to the canonical .gaia/artifacts/test-artifacts/
# path so the bash `set -u` regression doesn't leak through.
# resolve-config.sh's value wins when set.
TEST_ARTIFACTS="${TEST_ARTIFACTS:-.gaia/artifacts/test-artifacts}"
# The earlier validate-gate.sh traceability_exists check (which accepts
# flat | strategy/ | sharded) may already have PASSED — but the zero-byte
# guard re-probes ONLY the flat path, so it would falsely die "exists but
# empty" on a project whose matrix lives non-empty at strategy/ or the
# sharded index.md. The re-probe also needs to cover the canonical
# .gaia/artifacts/planning-artifacts/ home, so that /gaia-trace writing
# to the documented default location does not HALT here even though
# traceability_exists passed. Resolve TRACE_PATH via the shared
# resolve-artifact-path.sh helper, which puts planning-artifacts/ at
# rung 1 and keeps the test-artifacts flat / strategy/ / sharded
# read-compat rungs.
RESOLVE_ARTIFACT_PATH="$PLUGIN_SCRIPTS_DIR/lib/resolve-artifact-path.sh"
TRACE_PATH=""
if [ -x "$RESOLVE_ARTIFACT_PATH" ]; then
  TRACE_PATH="$("$RESOLVE_ARTIFACT_PATH" traceability --existing-only 2>/dev/null || true)"
fi
if [ -z "$TRACE_PATH" ]; then
  # Resolver found nothing non-empty; fall back to the legacy local probe so the
  # -s guard below emits the canonical "not found or empty" HALT.
  TRACE_PATH="${TEST_ARTIFACTS}/traceability-matrix.md"
  if [ ! -f "$TRACE_PATH" ]; then
    if [ -f "${TEST_ARTIFACTS}/strategy/traceability-matrix.md" ]; then
      TRACE_PATH="${TEST_ARTIFACTS}/strategy/traceability-matrix.md"
    elif [ -f "${TEST_ARTIFACTS}/traceability-matrix/index.md" ]; then
      TRACE_PATH="${TEST_ARTIFACTS}/traceability-matrix/index.md"
    fi
  fi
fi
if [ ! -s "$TRACE_PATH" ]; then
  die "HALT: traceability-matrix.md not found or empty at any accepted placement (planning-artifacts/ canonical, or test-artifacts flat / strategy/ / sharded) — run /gaia-trace to populate it"
fi

# ---------- 2c. Guard: ci-setup.md must be non-empty ----------
# Skipped when ci_platform.provider=none.
if [ "$NEEDS_CI_GATE" -eq 1 ]; then
  CI_PATH="${TEST_ARTIFACTS}/ci-setup.md"
  if [ ! -s "$CI_PATH" ]; then
    die "HALT: ci-setup.md exists but is empty (zero-byte) — run /gaia-ci-setup to populate it"
  fi
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
