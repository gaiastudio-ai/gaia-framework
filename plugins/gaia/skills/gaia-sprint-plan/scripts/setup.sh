#!/usr/bin/env bash
# setup.sh — sprint-plan skill setup
#
# Follows the shared script pattern for sprint-plan.
# Resolves config via the shared resolve-config.sh foundation script,
# validates prerequisites, and loads checkpoint state.
#
# Prerequisites:
#   - epics-and-stories.md must exist in planning-artifacts/
#   - sprint-state.sh must be available in the plugin scripts tree
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

SCRIPT_NAME="gaia-sprint-plan/setup.sh"
WORKFLOW_NAME="sprint-plan"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-sprint-plan/scripts/setup.sh → ../../../scripts
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

# ---------- 2. Validate gate (sprint-state.sh required) ----------
SPRINT_STATE="$PLUGIN_SCRIPTS_DIR/sprint-state.sh"
[ -x "$SPRINT_STATE" ] || die "sprint-state.sh not found or not executable at $SPRINT_STATE"

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

# ---------- 4. Lifecycle gates ----------
# Hard-error when upstream MANDATORY skills' artifacts are missing AND no
# `--bypass` recorded for the active sprint in `.gaia/state/lifecycle-overrides.yaml`.
# Source the lifecycle-overrides helper for bypass reads.

LIFECYCLE_LIB="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts/lib/lifecycle-overrides.sh"
STRICT_HELPER="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts/lib/lifecycle-strict-mode.sh"

# Bootstrap-state guard: the lifecycle gates are project-state-aware. When
# upstream artifacts and the lifecycle-overrides ledger are both absent
# (fresh-init projects, audit/e2e fixtures, brownfield-onboarding probes),
# the project has no canonical history yet and the gates would always fire
# spuriously. Detecting this BEFORE strict-mode resolution keeps e2e fixtures
# and audit-v2-migration fixtures green.
#
# Trigger condition: enforce gates only when EITHER the upstream artifact
# being checked exists OR a `.gaia/state/lifecycle-overrides.yaml` is
# present (indicating the operator is using the bypass workflow). When
# both are absent, treat as fixture context and skip.
# The bootstrap-skip probe + the active gates below delegate path-resolution
# to validate-gate.sh (which accepts flat | strategy/ | sharded) while
# KEEPING the strict-mode + bypass-record wrapper intact
# (validate-gate.sh has no strict/bypass awareness).
GATE_LIFECYCLE_LEDGER="${GAIA_STATE_DIR:-.gaia/state}/lifecycle-overrides.yaml"
# Resolve the planning/test artifact dirs with the SAME precedence
# validate-gate.sh uses — uppercase PLANNING_ARTIFACTS/TEST_ARTIFACTS
# exported by resolve-config.sh (and by the audit-v2-migration enriched
# fixture), then `.gaia/artifacts/...` canonical, then `docs/...`.
_resolve_planning_dir() {
  if [ -n "${PLANNING_ARTIFACTS:-}" ]; then
    printf '%s' "$PLANNING_ARTIFACTS"
  elif [ -d "${CLAUDE_PROJECT_ROOT:-.}/.gaia/artifacts/planning-artifacts" ]; then
    printf '%s' "${CLAUDE_PROJECT_ROOT:-.}/.gaia/artifacts/planning-artifacts"
  else
    printf '%s' "docs/planning-artifacts"
  fi
}
_resolve_test_dir() {
  if [ -n "${TEST_ARTIFACTS:-}" ]; then
    printf '%s' "$TEST_ARTIFACTS"
  elif [ -d "${CLAUDE_PROJECT_ROOT:-.}/.gaia/artifacts/test-artifacts" ]; then
    printf '%s' "${CLAUDE_PROJECT_ROOT:-.}/.gaia/artifacts/test-artifacts"
  else
    printf '%s' "docs/test-artifacts"
  fi
}
# Multi-path traceability existence probe via validate-gate.sh (exit 0 = present
# at any accepted placement). Falls back to the resolver-aligned dir when the
# script is absent, so the probe never crashes.
_trace_present() {
  if [ -x "$VALIDATE_GATE" ]; then
    "$VALIDATE_GATE" traceability_exists >/dev/null 2>&1
  else
    local td; td="$(_resolve_test_dir)"
    [ -f "$td/traceability-matrix.md" ] \
      || [ -f "$td/strategy/traceability-matrix.md" ] \
      || [ -f "$td/traceability-matrix/index.md" ]
  fi
}
# Multi-path readiness-report existence probe: gaia-readiness-check produces
# readiness-report.md with a frontmatter status: PASS|FAIL|CONDITIONAL.
_readiness_report_present() {
  if [ -x "$VALIDATE_GATE" ]; then
    "$VALIDATE_GATE" readiness_report_exists >/dev/null 2>&1
  else
    local pd; pd="$(_resolve_planning_dir)"
    [ -f "$pd/readiness-report.md" ] || [ -f "$pd/readiness-report/index.md" ]
  fi
}
if [ ! -f "$GATE_LIFECYCLE_LEDGER" ] && ! _trace_present && ! _readiness_report_present; then
  log "lifecycle gates skipped: no upstream artifacts and no overrides ledger (fresh-init or fixture context)"
  log "setup complete for $WORKFLOW_NAME"
  exit 0
fi

# Strict-mode resolution (falls back to ON when helper absent).
strict_mode_on=1
if [ -x "$STRICT_HELPER" ]; then
  if "$STRICT_HELPER" lifecycle_strict_mode_enabled >/dev/null 2>&1; then
    strict_mode_on=1
  else
    strict_mode_on=0
  fi
fi

if [ -f "$LIFECYCLE_LIB" ]; then
  SPRINT_ID_FOR_GATE="${SPRINT_ID:-${sprint_id:-}}"
  bypass_payload=""
  if [ -n "$SPRINT_ID_FOR_GATE" ]; then
    bypass_payload="$(bash "$LIFECYCLE_LIB" read --sprint-id "$SPRINT_ID_FOR_GATE" 2>/dev/null || echo '{"bypasses":[]}')"
  fi
  _has_bypass_for() {
    local skill="$1"
    printf '%s' "$bypass_payload" | jq -e --arg s "$skill" '.bypasses | any(.skill == $s or .skill == ("/" + $s))' >/dev/null 2>&1
  }

  # ---- Gate: traceability-matrix.md (flat | strategy/ | sharded via validate-gate.sh) ----
  if ! _trace_present; then
    if _has_bypass_for "gaia-trace"; then
      log "traceability gate bypassed: bypass record found for /gaia-trace"
    elif [ "$strict_mode_on" -eq 0 ]; then
      log "WARNING: traceability-matrix.md not found — would block in strict mode (run /gaia-trace OR --bypass gaia-trace --reason \"<text>\")"
    else
      die "traceability-matrix.md not found; run /gaia-trace OR add --bypass gaia-trace --reason \"<text>\""
    fi
  fi

  # ---- Gate: /gaia-readiness-check verdict ----
  # gaia-readiness-check produces readiness-report.md with a frontmatter
  # `status: PASS|FAIL|CONDITIONAL`. Gate on the report's status:
  # PASS or CONDITIONAL clears (CONDITIONAL is a known-gaps pass per the
  # readiness-check contract); FAIL or absent report does not.
  has_passed_readiness=0
  readiness_report_is_stub=0
  if _readiness_report_present; then
    _pd="$(_resolve_planning_dir)"
    READINESS_REPORT="$_pd/readiness-report.md"
    [ -f "$READINESS_REPORT" ] || READINESS_REPORT="$_pd/readiness-report/index.md"
    # Read the frontmatter status line (PASS / CONDITIONAL clears; FAIL does not).
    if grep -qE "^[[:space:]]*status:[[:space:]]*(PASS|PASSED|CONDITIONAL)" "$READINESS_REPORT" 2>/dev/null; then
      has_passed_readiness=1
    elif ! grep -qE "^[[:space:]]*status:[[:space:]]*\S" "$READINESS_REPORT" 2>/dev/null; then
      # The report exists but carries no `status:` frontmatter field — i.e. a
      # placeholder/stub, not a real readiness verdict. A genuine
      # gaia-readiness-check report always emits `status:`. Treat a field-less
      # stub as bootstrap/fixture context: downgrade the hard die to a WARNING.
      # A report WITH a status field (incl. `status: FAIL`) is a real verdict
      # and still gates in strict mode.
      readiness_report_is_stub=1
    fi
  fi
  if [ "$has_passed_readiness" -eq 0 ]; then
    if _has_bypass_for "gaia-readiness-check"; then
      log "readiness gate bypassed: bypass record found for /gaia-readiness-check"
    elif [ "$readiness_report_is_stub" -eq 1 ]; then
      log "WARNING: readiness-report exists but has no status: field (placeholder/stub) — treating as bootstrap/fixture context; run /gaia-readiness-check to produce a real PASS/CONDITIONAL verdict"
    elif [ "$strict_mode_on" -eq 0 ]; then
      log "WARNING: no PASS/CONDITIONAL /gaia-readiness-check verdict on record — would block in strict mode (run /gaia-readiness-check OR --bypass gaia-readiness-check --reason \"<text>\")"
    else
      die "no PASS/CONDITIONAL /gaia-readiness-check verdict on record; run /gaia-readiness-check OR add --bypass gaia-readiness-check --reason \"<text>\""
    fi
  fi
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
