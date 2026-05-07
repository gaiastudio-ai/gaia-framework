#!/usr/bin/env bash
# resolve-mode.sh — gaia-meeting active-mode resolver (E76-S1, FR-MTG-17, FR-MTG-16)
#
# Resolves the active mode from CLI args. When --mode is absent, returns
# "decide" (default per FR-MTG-17). Rejects mode stacking (multiple --mode
# flags) per the FR-MTG-16 single-mode-only invariant. Rejects unknown modes.
#
# Known modes (S1 documents the full set; only "decide" is functionally wired
# in S1 — the other eight ship in E76-S5):
#   decide brainstorm research-deepdive incident review
#   estimate retro design-critique architecture
#
# Usage:
#   resolve-mode.sh                   # -> "decide"
#   resolve-mode.sh --mode brainstorm # -> "brainstorm"
#
# Exit codes:
#   0 = active mode echoed on stdout
#   2 = mode stacking detected (FR-MTG-16 violation)
#   3 = unknown mode
#   4 = malformed args

set -euo pipefail

KNOWN_MODES=(decide brainstorm research-deepdive incident review estimate retro design-critique architecture)

MODE=""
MODE_COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE_COUNT=$((MODE_COUNT + 1))
      MODE="${2-}"
      shift 2
      ;;
    --mode=*)
      MODE_COUNT=$((MODE_COUNT + 1))
      MODE="${1#--mode=}"
      shift
      ;;
    *)
      echo "resolve-mode.sh: unknown argument: $1" >&2
      exit 4
      ;;
  esac
done

if [[ "$MODE_COUNT" -gt 1 ]]; then
  echo "resolve-mode.sh: single-mode-only invariant violated — only one --mode flag is allowed (FR-MTG-16)." >&2
  exit 2
fi

if [[ -z "$MODE" ]]; then
  MODE="decide"
fi

# Validate against the known set
known=0
for m in "${KNOWN_MODES[@]}"; do
  if [[ "$m" == "$MODE" ]]; then
    known=1
    break
  fi
done

if [[ "$known" -ne 1 ]]; then
  echo "resolve-mode.sh: unknown mode '$MODE'. Known modes: ${KNOWN_MODES[*]}" >&2
  exit 3
fi

echo "$MODE"
exit 0
