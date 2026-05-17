#!/usr/bin/env bash
# resolve-mode.sh — gaia-meeting active-mode resolver (E76-S1, E76-S5)
#
# FR-MTG-17 / FR-MTG-16
#
# Resolves the active mode from CLI args. When --mode is absent, returns
# "decide" (default per FR-MTG-17). Rejects mode stacking (multiple --mode
# flags) per the FR-MTG-16 single-mode-only invariant. Rejects unknown modes.
#
# E76-S5 — mode set is now sourced from the registry at
# `knowledge/modes.yaml` (FR-MTG-17), and aliases (currently only `ux` →
# `design`) are canonicalised here so downstream consumers see only the
# canonical mode name.
#
# Usage:
#   resolve-mode.sh                   # -> "decide"
#   resolve-mode.sh --mode brainstorm # -> "brainstorm"
#   resolve-mode.sh --mode ux         # -> "design" (alias resolution)
#
# Exit codes:
#   0 = active mode echoed on stdout (canonical)
#   2 = mode stacking detected (FR-MTG-16 violation)
#   3 = unknown mode
#   4 = malformed args

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/load-mode-registry.sh
. "$SCRIPT_DIR/lib/load-mode-registry.sh"

MODE=""
MODE_COUNT=0
SUPPLIED_MODES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE_COUNT=$((MODE_COUNT + 1))
      MODE="${2-}"
      SUPPLIED_MODES+=("$MODE")
      shift 2
      ;;
    --mode=*)
      MODE_COUNT=$((MODE_COUNT + 1))
      MODE="${1#--mode=}"
      SUPPLIED_MODES+=("$MODE")
      shift
      ;;
    *)
      echo "resolve-mode.sh: unknown argument: $1" >&2
      exit 4
      ;;
  esac
done

if [[ "$MODE_COUNT" -gt 1 ]]; then
  # AC9 — error message MUST list both supplied values and reference FR-MTG-16.
  echo "resolve-mode.sh: single-mode-only invariant violated (FR-MTG-16) — only one --mode flag is allowed in v1; supplied: ${SUPPLIED_MODES[*]}" >&2
  exit 2
fi

# Reject `--mode=` and `--mode ""` explicitly — silent fallback to `decide`
# masked user-intent bugs where `--mode "${SOMETHING}"` expanded an unset
# variable into an empty string (see manual-test finding F9, gaia-meeting
# QA, 2026-05-18). Distinct from the "no --mode flag at all" path below.
if [[ "$MODE_COUNT" -eq 1 && -z "$MODE" ]]; then
  echo "resolve-mode.sh: --mode requires a non-empty value (omit --mode entirely to use the 'decide' default)" >&2
  exit 4
fi

if [[ -z "$MODE" ]]; then
  MODE="decide"
fi

# Canonicalise via the registry (handles aliases such as ux -> design).
canonical="$(mode_registry_canonical "$MODE" || true)"
if [[ -z "$canonical" ]]; then
  KNOWN="$(mode_registry_known_modes | tr '\n' ' ')"
  echo "resolve-mode.sh: unknown mode '$MODE'. Known modes: ${KNOWN}" >&2
  exit 3
fi

echo "$canonical"
exit 0
