#!/usr/bin/env bash
# design-stale-transition.sh — shared driver for stale-on-change propagation.
#
# Bang-run by add-feature and edit-ux SKILL.md to transition the design
# record to stale when a design-affecting change is detected, then halt
# when the integration is unavailable.
#
# Usage:
#   design-stale-transition.sh --decision <yes|no|ambiguous> --actor <name> \
#     [--integration <available|missing|unauthorized>]
#
# The --integration flag carries the skill-attested integration state.
# When present, the driver trusts it and does not run the probe. When
# absent, the probe fallback runs and the result is fail-closed (unknown
# output is treated as missing).
#
# Decision matrix:
#   no        — exit 0, no transition, record unchanged
#   yes       — resolve state, transition to stale, halt on unavailable
#   ambiguous — same as yes (fail-safe: default to stale when uncertain)
#
# Ordering: the integration state is resolved first (attested value or
# probe fallback), then the stale transition is written (with the state
# and its source recorded in the audit entry), and only then does the
# driver halt when the state is not available.
#
# Trade-off: a driver killed during the probe fallback leaves the record
# not yet stale, because the probe is part of state resolution, which
# precedes the stale write.
#
# Authorization-expiry: when a skill attests available, the driver trusts
# it without re-probing. If the token is revoked between the skill's
# check and the driver run, the later Claude Design update step surfaces
# the failure — it is not silently absorbed.
#
# Probe classification is read from the probe's STDOUT (not exit code).
# Three known values: available, missing, unauthorized. Any other value
# is treated as missing (fail-closed). The probe's stderr remediation is
# relayed verbatim on the probed path.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DREC_SCRIPT="$SCRIPT_DIR/design-record.sh"
PROBE_SCRIPT="$SCRIPT_DIR/design-probe.sh"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

_decision=""
_actor=""
_integration=""
_integration_seen=0
_probe_stderr=""

while [ $# -gt 0 ]; do
  case "$1" in
    --decision) _decision="$2"; shift 2 ;;
    --actor)    _actor="$2";    shift 2 ;;
    --integration)
      if [ $# -lt 2 ]; then
        printf 'design-stale-transition.sh: --integration requires a value; legal values: available, missing, unauthorized\n' >&2
        exit 2
      fi
      if [ "$_integration_seen" -eq 1 ]; then
        printf 'design-stale-transition.sh: --integration specified more than once\n' >&2
        exit 2
      fi
      _integration="$2"
      _integration_seen=1
      shift 2 ;;
    *)          shift ;;
  esac
done

[ -n "$_decision" ] || { printf 'design-stale-transition.sh: --decision required\n' >&2; exit 2; }
[ -n "$_actor" ]    || { printf 'design-stale-transition.sh: --actor required\n' >&2; exit 2; }

# Validate --integration value before any decision or mutation
if [ "$_integration_seen" -eq 1 ]; then
  case "$_integration" in
    available|missing|unauthorized) ;;  # MUTANT-ANCHOR: enum-validation
    *)
      printf 'design-stale-transition.sh: invalid --integration value: %s; legal values: available, missing, unauthorized\n' \
        "$(printf '%s' "$_integration" | tr -c '[:print:]' '?')" >&2
      exit 2 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Decision dispatch
# ---------------------------------------------------------------------------

if [ "$_decision" = "no" ]; then
  exit 0
fi

# yes or ambiguous — resolve state, write stale, then halt if not available

# ---------------------------------------------------------------------------
# Phase 1: resolve integration state
# ---------------------------------------------------------------------------

_resolved_state=""
_resolved_source=""

if [ "$_integration_seen" -eq 1 ]; then  # MUTANT-ANCHOR: attestation-guard
  _resolved_state="$_integration"
  _resolved_source="attested"
else
  # Probe fallback — fail-closed
  _resolved_state="missing"  # MUTANT-ANCHOR: probe-fallback-default
  _resolved_source="probed"

  if [ -f "$PROBE_SCRIPT" ]; then
    _probe_stderr="$(mktemp -t dst-probe-stderr.XXXXXX)"
    trap 'rm -f "$_probe_stderr" 2>/dev/null || true' EXIT

    _probe_stdout="$("$PROBE_SCRIPT" 2>"$_probe_stderr")" || true
    _probe_stdout="$(printf '%s' "$_probe_stdout" | head -1)"

    case "$_probe_stdout" in
      available)    _resolved_state="available" ;;
      unauthorized) _resolved_state="unauthorized" ;;
      *)            ;; # keep fail-closed default
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Phase 2: write stale transition with audit
# ---------------------------------------------------------------------------

"$DREC_SCRIPT" transition --to stale --actor "$_actor" \
  --integration-state "$_resolved_state" --integration-source "$_resolved_source"

# ---------------------------------------------------------------------------
# Phase 3: halt if not available
# ---------------------------------------------------------------------------

case "$_resolved_state" in
  available)
    rm -f "$_probe_stderr" 2>/dev/null || true
    exit 0
    ;;
  unauthorized)
    printf 'design-stale-transition.sh: design-first ordering cannot be kept — the design integration is unauthorized in this session. Run /design-login to authorize the integration.\n' >&2
    if [ -n "$_probe_stderr" ] && [ -f "$_probe_stderr" ]; then
      cat "$_probe_stderr" >&2 2>/dev/null || true
    fi
    rm -f "$_probe_stderr" 2>/dev/null || true
    exit 1
    ;;
  *)
    printf 'design-stale-transition.sh: design-first ordering cannot be kept — the design integration is not available in this session. Enable the Claude Design integration, or use a Claude Code session that exposes the design tool surface.\n' >&2
    if [ -n "$_probe_stderr" ] && [ -f "$_probe_stderr" ]; then
      cat "$_probe_stderr" >&2 2>/dev/null || true
    fi
    rm -f "$_probe_stderr" 2>/dev/null || true
    exit 1
    ;;
esac
