#!/usr/bin/env bash
# turn-order.sh — gaia-meeting round-robin turn arbitration
#
# Emits a deterministic round-robin sequence of speaker labels matching the
# invite order, one speaker per line. Drives the DISCUSS-phase turn loop.
#
# Usage:
#   turn-order.sh --invitees "P1,P2,P3" --turns 6
#
# Output (stdout): one speaker per line, in order.
#
# Exit codes:
#   0 = sequence emitted
#   2 = empty invitee list
#   3 = malformed args / non-positive turn count

set -euo pipefail

INVITEES=""
TURNS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --invitees)
      INVITEES="${2-}"
      shift 2
      ;;
    --invitees=*)
      INVITEES="${1#--invitees=}"
      shift
      ;;
    --turns)
      TURNS="${2-}"
      shift 2
      ;;
    --turns=*)
      TURNS="${1#--turns=}"
      shift
      ;;
    *)
      echo "turn-order.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$INVITEES" ]]; then
  echo "turn-order.sh: --invitees is required and must be non-empty." >&2
  exit 2
fi

if ! [[ "$TURNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "turn-order.sh: --turns must be a positive integer (got: '$TURNS')." >&2

  exit 3
fi

# Split CSV into bash array
IFS=',' read -r -a INVITEE_ARR <<< "$INVITEES"
n=${#INVITEE_ARR[@]}

if [[ "$n" -eq 0 ]]; then
  echo "turn-order.sh: invitee list is empty after split." >&2
  exit 2
fi

for ((t = 0; t < TURNS; t++)); do
  idx=$((t % n))
  echo "${INVITEE_ARR[$idx]}"
done

exit 0
