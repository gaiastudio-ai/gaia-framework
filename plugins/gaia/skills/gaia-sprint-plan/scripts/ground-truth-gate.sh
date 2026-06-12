#!/usr/bin/env bash
# ground-truth-gate.sh — sprint-plan Step 0 ENTRY blocking gate.
#
# Wired into /gaia-sprint-plan Step 0, AFTER the prior-close guard and BEFORE
# story selection (placement asymmetry: sprint-plan operates on FRESH truth
# BEFORE planning decisions). Sources the shared gate helper and runs the
# BLOCKING gate: on STALE it prints a diagnostic naming stale ground-truth +
# the incremental-refresh instruction and exits non-zero so planning halts.
#
# Executable entry point (the SKILL.md Step 0 calls this script directly). It
# is a thin wrapper — the staleness decision lives ONLY in the shared
# scripts/lib/ground-truth-stale-check.sh predicate, never re-inlined here.
#
# Exit codes:
#   0 — FRESH (or could-evaluate-and-fresh) → proceed with planning
#   1 — STALE / uncertain → HALT planning with a diagnostic on stderr

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE_LIB="$(cd "$SCRIPT_DIR/../../../scripts/lib" && pwd)/ground-truth-gate.sh"

if [ ! -r "$GATE_LIB" ]; then
  printf 'gaia-sprint-plan/ground-truth-gate.sh: BLOCKED — shared gate helper not found at %s\n' \
    "$GATE_LIB" >&2
  exit 1
fi

# shellcheck source=/dev/null
. "$GATE_LIB"

gt_gate_blocking "sprint-plan-entry"
