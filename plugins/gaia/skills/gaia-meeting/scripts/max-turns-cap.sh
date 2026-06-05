#!/usr/bin/env bash
# max-turns-cap.sh — gaia-meeting max-turns guardrail
#
# Default cap = 40, override via --max-turns N. Rejects the (cap+1)th emitted
# turn BEFORE emission — the orchestrator is expected to log a termination
# event in the transcript epilogue on rejection.
#
# Usage:
#   max-turns-cap.sh --check --emitted-turns N [--max-turns CAP]
#
# Exit codes:
#   0 = under cap (turn allowed)
#   2 = at or over cap+1 (turn rejected; explanation on stdout)
#   3 = malformed args

set -euo pipefail

DEFAULT_CAP=40
MAX_TURNS="$DEFAULT_CAP"
EMITTED_TURNS=""
CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)              CHECK=1; shift ;;
    --emitted-turns)      EMITTED_TURNS="${2-}"; shift 2 ;;
    --emitted-turns=*)    EMITTED_TURNS="${1#--emitted-turns=}"; shift ;;
    --max-turns)          MAX_TURNS="${2-}"; shift 2 ;;
    --max-turns=*)        MAX_TURNS="${1#--max-turns=}"; shift ;;
    *)
      echo "max-turns-cap.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ "$CHECK" -ne 1 ]]; then
  echo "max-turns-cap.sh: --check is required" >&2
  exit 3
fi

if ! [[ "$EMITTED_TURNS" =~ ^[0-9]+$ ]]; then
  echo "max-turns-cap.sh: --emitted-turns must be a non-negative integer (got: '$EMITTED_TURNS')" >&2
  exit 3
fi

# --max-turns must be a strictly positive integer.
if ! [[ "$MAX_TURNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "max-turns-cap.sh: --max-turns must be a positive integer (got: '$MAX_TURNS')" >&2
  exit 3
fi

if [[ "$EMITTED_TURNS" -le "$MAX_TURNS" ]]; then
  exit 0
fi

echo "max-turns-cap.sh: REJECTED — MAX-TURNS-CAP reached (emitted=$EMITTED_TURNS, cap=$MAX_TURNS)."
echo "max-turns-cap.sh: meeting must terminate; epilogue will record the cap-cross termination event."
exit 2
