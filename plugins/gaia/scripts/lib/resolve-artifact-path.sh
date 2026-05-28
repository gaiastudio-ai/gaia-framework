#!/usr/bin/env bash
# resolve-artifact-path.sh — single source of truth for the read-path
# precedence of the artifacts whose canonical home moved under the .gaia/
# consolidation (ADR-111) and the E105-S2 / ADR-127 §7.2 docs-about-testing
# relocation.
#
# Background (AF-2026-05-27-8 / Test06 F-007, F-008, F-011, F-014):
#   Three consecutive manual-test runs surfaced the SAME bug class — individual
#   setup.sh / finalize.sh / dashboard scripts each hard-code their own
#   path-precedence list, and those lists drifted out of sync with the
#   PRODUCER (e.g. /gaia-test-strategy now writes test-plan/test-strategy under
#   planning-artifacts/, but the create-epics + readiness-check consumers still
#   only looked under test-artifacts/). Each drift presents as a FALSE HALT on
#   the canonical layout. This helper centralises the precedence so the class
#   cannot recur a fourth time: every consumer asks THIS script, and the
#   canonical post-ADR-111 / post-E105-S2 location is always rung 1.
#
# Canonical homes (rung 1 for each kind):
#   test_plan        .gaia/artifacts/planning-artifacts/test-plan.md      (E105-S2 / ADR-127 §7.2)
#   test_strategy    .gaia/artifacts/planning-artifacts/test-strategy.md  (E105-S2 / ADR-127 §7.2)
#   traceability     .gaia/artifacts/planning-artifacts/traceability-matrix.md (E105-S2 / ADR-127 §7.2)
#   sprint_status    .gaia/state/sprint-status.yaml                       (ADR-111 mutable-state tier)
#   ci_setup         .gaia/artifacts/test-artifacts/ci-setup.md           (test-artifacts tier)
#
# Usage:
#   resolve-artifact-path.sh <kind> [--project-root <dir>] [--existing-only]
#
#   <kind>            one of: test_plan | test_strategy | traceability |
#                     sprint_status | ci_setup
#   --project-root    project root (default: $CLAUDE_PROJECT_ROOT or $PWD)
#   --existing-only   print a path ONLY if a non-empty file exists at one of
#                     the precedence rungs; exit 1 (no stdout) when none exist.
#                     Without this flag the script prints the FIRST existing
#                     non-empty rung, or the canonical rung-1 path when none
#                     exist (so callers get a stable "expected" path for error
#                     messages — matching validate-gate.sh's contract).
#
# Exit codes:
#   0 — resolved (stdout = path)
#   1 — --existing-only and no rung exists, OR unknown kind / bad args
#
# This helper is READ-ONLY: it never creates directories or files. Producers
# always write to the canonical rung-1 home regardless of what this returns
# (mirrors the artifact-three-tier-resolve.sh "no legacy-writes" clause).

set -euo pipefail

SCRIPT_NAME="resolve-artifact-path.sh"

usage() {
  cat >&2 <<USAGE
usage: ${SCRIPT_NAME} <kind> [--project-root <dir>] [--existing-only]
  kind: test_plan | test_strategy | traceability | sprint_status | ci_setup
USAGE
  exit 1
}

[ $# -ge 1 ] || usage
KIND="$1"; shift

# Project-root precedence mirrors the framework's other root-resolvers so a
# caller that exports any of the canonical root env-vars (or runs from a
# different CWD than the project, as the cluster-6 e2e fixture does) resolves
# correctly: CLAUDE_PROJECT_ROOT → GAIA_PROJECT_ROOT → PROJECT_ROOT →
# PROJECT_PATH → PWD. An explicit --project-root flag overrides all of these.
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-${PROJECT_ROOT:-${PROJECT_PATH:-${PWD}}}}}"
EXISTING_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --existing-only) EXISTING_ONLY=1; shift ;;
    *) usage ;;
  esac
done

PA="${PROJECT_ROOT}/.gaia/artifacts/planning-artifacts"
TA="${PROJECT_ROOT}/.gaia/artifacts/test-artifacts"
IA="${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts"
ST="${PROJECT_ROOT}/.gaia/state"
LEGACY_PA="${PROJECT_ROOT}/docs/planning-artifacts"
LEGACY_TA="${PROJECT_ROOT}/docs/test-artifacts"
LEGACY_IA="${PROJECT_ROOT}/docs/implementation-artifacts"

# Build the precedence list for the requested kind. Rung 1 is ALWAYS the
# canonical post-ADR-111 / post-E105-S2 home. Subsequent rungs are read-compat
# fallbacks for in-migration projects and pre-ADR-072 strategy/ placement.
CANDIDATES=()
case "$KIND" in
  test_plan)
    CANDIDATES=(
      "${PA}/test-plan.md"
      "${PA}/test-strategy.md"
      "${TA}/test-plan.md"
      "${TA}/strategy/test-plan.md"
      "${TA}/strategy/test-strategy.md"
      "${TA}/test-plan/index.md"
      "${LEGACY_PA}/test-plan.md"
      "${LEGACY_TA}/test-plan.md"
      "${LEGACY_TA}/strategy/test-plan.md"
    )
    ;;
  test_strategy)
    CANDIDATES=(
      "${PA}/test-strategy.md"
      "${TA}/strategy/test-strategy.md"
      "${LEGACY_PA}/test-strategy.md"
      "${LEGACY_TA}/strategy/test-strategy.md"
    )
    ;;
  traceability)
    CANDIDATES=(
      "${PA}/traceability-matrix.md"
      "${TA}/traceability-matrix.md"
      "${TA}/strategy/traceability-matrix.md"
      "${TA}/traceability-matrix/index.md"
      "${LEGACY_PA}/traceability-matrix.md"
      "${LEGACY_TA}/traceability-matrix.md"
    )
    ;;
  sprint_status)
    CANDIDATES=(
      "${ST}/sprint-status.yaml"
      "${IA}/sprint-status.yaml"
      "${LEGACY_IA}/sprint-status.yaml"
      "${PROJECT_ROOT}/sprint-status.yaml"
    )
    ;;
  ci_setup)
    CANDIDATES=(
      "${TA}/ci-setup.md"
      "${LEGACY_TA}/ci-setup.md"
    )
    ;;
  *)
    printf '%s: unknown kind: %s\n' "$SCRIPT_NAME" "$KIND" >&2
    usage
    ;;
esac

# Walk the precedence — first non-empty file wins.
for cand in "${CANDIDATES[@]}"; do
  if [ -s "$cand" ]; then
    printf '%s\n' "$cand"
    exit 0
  fi
done

# No existing rung found.
if [ "$EXISTING_ONLY" -eq 1 ]; then
  exit 1
fi

# Fall back to the canonical rung-1 path so callers have a stable "expected"
# path string for error messages (matches validate-gate.sh's contract).
printf '%s\n' "${CANDIDATES[0]}"
exit 0
