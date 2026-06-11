#!/usr/bin/env bash
# ground-truth-gate.sh — shared lifecycle-gate wrapper around the staleness
# predicate (scripts/lib/ground-truth-stale-check.sh).
#
# Sourceable, NOT executable. Exposes TWO functions so every lifecycle point
# decides "is ground-truth stale, and what do I do about it?" IDENTICALLY —
# the same DRY discipline that put the find-newer predicate in one shared lib.
# Do NOT re-inline a staleness check in any ceremony; source this file and call
# one of these two functions.
#
#   gt_gate_blocking  [LABEL]
#       BLOCKING gate (sprint-plan Step 0 entry, add-feature completion).
#       On STALE: print a diagnostic naming stale ground-truth + the operator's
#       next action (`/gaia-refresh-ground-truth --incremental`) to stderr and
#       return NON-ZERO so the caller halts the ceremony. On FRESH: silent,
#       return 0.
#
#   gt_gate_best_effort  [LABEL]
#       BEST-EFFORT gate (sprint-close, story-done). On STALE OR any internal
#       failure: WARN to stderr and return 0 (NEVER fail the ceremony). On
#       FRESH: silent, return 0. Fail-safe: a failure to even evaluate the
#       predicate degrades to a warning, never a hard error.
#
# Refresh-invocation policy (auto-trigger contract):
#   Auto-triggers instruct the INCREMENTAL refresh only. A bash finalize cannot
#   honestly self-invoke another GAIA skill, so the mechanically-honest action
#   is: emit the diagnostic instructing `/gaia-refresh-ground-truth
#   --incremental`. Auto-triggers MUST NEVER instruct `--agent all` — that is
#   the deferred manual-only full refresh.
#
# Portability: bash 3.2, LC_ALL=C, BSD + GNU. shellcheck clean.

if [ "${_GAIA_GT_GATE_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317  # reached only when executed, not sourced
  return 0 2>/dev/null || exit 0
fi
_GAIA_GT_GATE_LOADED=1

# Resolve and source the staleness predicate relative to THIS file so the gate
# works regardless of the caller's CWD.
# shellcheck source=/dev/null
_gt_gate_source_predicate() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -z "${_GAIA_GT_STALE_CHECK_LOADED:-}" ] || [ "${_GAIA_GT_STALE_CHECK_LOADED:-0}" != "1" ]; then
    . "$here/ground-truth-stale-check.sh"
  fi
}

# The canonical operator next-action string. INCREMENTAL only — never the
# deferred `--agent all` full refresh.
_GT_GATE_REFRESH_HINT="run: /gaia-refresh-ground-truth --incremental"

# gt_gate_blocking [LABEL] — STALE → diagnostic + non-zero; FRESH → silent, 0.
gt_gate_blocking() {
  local label="${1:-lifecycle}"
  local verdict
  _gt_gate_source_predicate || {
    # Could not even load the predicate: a BLOCKING gate fails safe by HALTING
    # (uncertain → block), with a diagnostic.
    printf 'ground-truth gate [%s]: BLOCKED — could not evaluate ground-truth staleness; %s\n' \
      "$label" "$_GT_GATE_REFRESH_HINT" >&2
    return 1
  }
  verdict="$(check_ground_truth_staleness 2>/dev/null)"
  if [ "$verdict" = "STALE" ]; then
    printf 'ground-truth gate [%s]: BLOCKED — validator-sidecar ground-truth is STALE.\n' "$label" >&2
    printf 'ground-truth gate [%s]: refresh before proceeding — %s\n' "$label" "$_GT_GATE_REFRESH_HINT" >&2
    return 1
  fi
  return 0
}

# gt_gate_best_effort [LABEL] — STALE/failure → warn + 0; FRESH → silent, 0.
gt_gate_best_effort() {
  local label="${1:-lifecycle}"
  local verdict
  if ! _gt_gate_source_predicate; then
    printf 'ground-truth gate [%s]: warning — could not evaluate ground-truth staleness; continuing (best-effort)\n' \
      "$label" >&2
    return 0
  fi
  verdict="$(check_ground_truth_staleness 2>/dev/null)" || {
    printf 'ground-truth gate [%s]: warning — ground-truth staleness check failed; continuing (best-effort)\n' \
      "$label" >&2
    return 0
  }
  if [ "$verdict" = "STALE" ]; then
    printf 'ground-truth gate [%s]: warning — validator-sidecar ground-truth is STALE; %s — continuing (best-effort)\n' \
      "$label" "$_GT_GATE_REFRESH_HINT" >&2
  fi
  return 0
}

# shellcheck disable=SC2317  # reached only when executed, not sourced
return 0 2>/dev/null || true
