#!/usr/bin/env bash
# design-stale-transition.sh — shared driver for stale-on-change propagation.
#
# Bang-invoked by add-feature and edit-ux SKILL.md to transition the design
# record to stale when a design-affecting change is detected, then probe
# the integration surface and halt when it is unavailable.
#
# Usage:
#   design-stale-transition.sh --decision <yes|no|ambiguous> --actor <name>
#
# Decision matrix:
#   no        — exit 0, no transition, record unchanged
#   yes       — transition to stale, probe, halt on unavailable
#   ambiguous — same as yes (fail-safe: default to stale when uncertain)
#
# Probe classification is read from the probe's STDOUT (not exit code).
# Three known values: available, missing, unauthorized. Any other value
# is treated as missing (fail-closed). The probe's stderr remediation is
# relayed verbatim.
#
# The record transitions to stale BEFORE the probe runs, so a probe
# failure leaves the record correctly stale.

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

while [ $# -gt 0 ]; do
  case "$1" in
    --decision) _decision="$2"; shift 2 ;;
    --actor)    _actor="$2";    shift 2 ;;
    *)          shift ;;
  esac
done

[ -n "$_decision" ] || { printf 'design-stale-transition.sh: --decision required\n' >&2; exit 2; }
[ -n "$_actor" ]    || { printf 'design-stale-transition.sh: --actor required\n' >&2; exit 2; }

# ---------------------------------------------------------------------------
# Decision dispatch
# ---------------------------------------------------------------------------

if [ "$_decision" = "no" ]; then
  exit 0
fi

# yes or ambiguous — transition to stale
"$DREC_SCRIPT" transition --to stale --actor "$_actor"

# ---------------------------------------------------------------------------
# Probe the integration surface
# ---------------------------------------------------------------------------

if [ ! -f "$PROBE_SCRIPT" ]; then
  printf 'design-stale-transition.sh: design-first ordering cannot be kept — probe script missing at %s\n' "$PROBE_SCRIPT" >&2
  exit 1
fi

# Capture probe stdout (classification) and stderr (remediation) separately.
# Branch on the stdout classification, never on exit code — the probe exits 1
# for both missing and unauthorized.
_probe_stderr="$(mktemp -t dst-probe-stderr.XXXXXX)"
_probe_state="$("$PROBE_SCRIPT" 2>"$_probe_stderr")" || true
_probe_state="$(printf '%s' "$_probe_state" | head -1)"

case "$_probe_state" in
  available)
    rm -f "$_probe_stderr" 2>/dev/null || true
    exit 0
    ;;
  missing)
    printf 'design-stale-transition.sh: design-first ordering cannot be kept — integration missing\n' >&2
    cat "$_probe_stderr" >&2 2>/dev/null || true
    rm -f "$_probe_stderr" 2>/dev/null || true
    exit 1
    ;;
  unauthorized)
    printf 'design-stale-transition.sh: design-first ordering cannot be kept — integration unauthorized\n' >&2
    cat "$_probe_stderr" >&2 2>/dev/null || true
    rm -f "$_probe_stderr" 2>/dev/null || true
    exit 1
    ;;
  *)
    # Unknown stdout — fail closed (treat as missing)
    printf 'design-stale-transition.sh: design-first ordering cannot be kept — unknown probe state: %s\n' "$_probe_state" >&2
    cat "$_probe_stderr" >&2 2>/dev/null || true
    rm -f "$_probe_stderr" 2>/dev/null || true
    exit 1
    ;;
esac
