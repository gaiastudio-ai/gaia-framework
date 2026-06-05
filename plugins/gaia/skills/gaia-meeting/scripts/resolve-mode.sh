#!/usr/bin/env bash
# resolve-mode.sh — gaia-meeting active-mode resolver
#
# Resolves the active mode from CLI args. When --mode is absent, returns
# "decide" (default). Rejects mode stacking (multiple --mode
# flags) per the single-mode-only invariant. Rejects unknown modes.
#
# The mode set is sourced from the registry at
# `knowledge/modes.yaml`, and aliases (currently only `ux` →
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
#   2 = mode stacking detected
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
  echo "resolve-mode.sh: single-mode-only invariant violated — only one --mode flag is allowed; supplied: ${SUPPLIED_MODES[*]}" >&2
  exit 2
fi

# Reject `--mode=` and `--mode ""` explicitly — silent fallback to `decide`
# masked user-intent bugs where `--mode "${SOMETHING}"` expanded an unset
# variable into an empty string. Distinct from the "no --mode flag at all" path below.
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
