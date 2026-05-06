#!/usr/bin/env bash
# probe-state-to-check-status.sh — single-source-of-truth mapping from probe
# state to analysis-results.json check.status enum (E70-S6, ADR-077, ADR-078).
#
# Purpose
# -------
# `tool-availability-probe.sh` (E66-S2) emits one of four states:
#   - available
#   - expected_and_missing
#   - ran_and_errored
#   - not_applicable
#
# Review skills and the verdict resolver consume `analysis-results.json` whose
# `checks[].status` is one of: passed | failed | errored | skipped.
#
# This helper encodes the canonical mapping between the two enums in exactly
# one place so the four-way switch is never duplicated inline across review
# skills, adapters, or the resolver. The mapping is documented in
# `plugins/gaia/scripts/adapters/BOUNDARIES.md` §Three-State Availability Probe
# and `plugins/gaia/scripts/adapters/_schema/run-contract.md` §5:
#
#   probe state              | check.status
#   -------------------------|--------------
#   available                | passed
#   expected_and_missing     | errored
#   ran_and_errored          | errored
#   not_applicable           | skipped
#
# Note that `failed` is reserved for review-skill-level findings (a tool ran
# successfully and reported blocking findings) — it is NOT a probe-state-derived
# check.status. The probe never produces `failed` directly.
#
# Invocation
# ----------
#   probe-state-to-check-status.sh --probe-state <state>
#   probe-state-to-check-status.sh --help
#
# Exit codes
# ----------
#   0  — known state; check.status emitted on stdout
#   1  — unknown state, missing flag, or other caller error
#
# Determinism
# -----------
# `set -euo pipefail` + `LC_ALL=C` + a literal `case` statement guarantee
# byte-identical output for identical inputs across every invocation. No
# environment reads beyond LC_ALL pinning. No external commands.
#
# Refs: ADR-077, ADR-078, FR-RSV2-3, FR-RSV2-18.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="probe-state-to-check-status.sh"

usage() {
  cat <<EOF
$SCRIPT_NAME — map a tool-availability-probe state to an analysis-results.json check.status enum (E70-S6).

Usage:
  $SCRIPT_NAME --probe-state <state>
  $SCRIPT_NAME --help

Required:
  --probe-state <state>   One of: available, expected_and_missing,
                          ran_and_errored, not_applicable.

Mapping (canonical — see BOUNDARIES.md §Three-State Availability Probe):
  available             -> passed
  expected_and_missing  -> errored
  ran_and_errored       -> errored
  not_applicable        -> skipped

Exit codes:
  0  Known state; check.status emitted on stdout.
  1  Unknown state, missing flag, or caller error.
EOF
}

die() {
  # die <exit_code> <message>
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

PROBE_STATE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --probe-state)
      [ "$#" -ge 2 ] || die 1 "--probe-state requires a value"
      PROBE_STATE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die 1 "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$PROBE_STATE" ] || die 1 "missing required --probe-state <state> (try --help)"

case "$PROBE_STATE" in
  available)
    printf '%s\n' "passed" ;;
  expected_and_missing|ran_and_errored)
    printf '%s\n' "errored" ;;
  not_applicable)
    printf '%s\n' "skipped" ;;
  *)
    die 1 "unknown probe state: $PROBE_STATE (valid: available, expected_and_missing, ran_and_errored, not_applicable)" ;;
esac
