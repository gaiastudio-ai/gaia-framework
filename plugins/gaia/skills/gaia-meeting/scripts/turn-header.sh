#!/usr/bin/env bash
# turn-header.sh — gaia-meeting per-turn header renderer (E76-S1, FR-MTG-10, NFR-MTG-1)
#
# Emits a deterministic single-line header for every emitted turn — including
# user interjections, raise-hand insertions (E76-S2), and research-interrupt
# insertions (E76-S2). The cadence counter (10-turn cost-check cadence) is
# advanced PER EMITTED TURN, not per round-robin slot — this matters once
# E76-S2's insertions arrive, since the determinism required by NFR-MTG-1
# depends on the per-emitted-turn count.
#
# Header format (single line, bracketed, no `>` prefix per FR-MTG-10):
#   [round R / turn T / Speaker (Role) / per-turn-cost N tokens / running-total M tokens]
#
# Usage:
#   turn-header.sh --round 1 --turn 1 --speaker "Theo" --role "Architect" \
#                  --turn-cost 100 --running-total 100
#
# Exit codes:
#   0 = header emitted
#   3 = malformed args

set -euo pipefail

ROUND=""
TURN=""
SPEAKER=""
ROLE=""
TURN_COST=""
RUNNING_TOTAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --round)         ROUND="${2-}"; shift 2 ;;
    --round=*)       ROUND="${1#--round=}"; shift ;;
    --turn)          TURN="${2-}"; shift 2 ;;
    --turn=*)        TURN="${1#--turn=}"; shift ;;
    --speaker)       SPEAKER="${2-}"; shift 2 ;;
    --speaker=*)     SPEAKER="${1#--speaker=}"; shift ;;
    --role)          ROLE="${2-}"; shift 2 ;;
    --role=*)        ROLE="${1#--role=}"; shift ;;
    --turn-cost)     TURN_COST="${2-}"; shift 2 ;;
    --turn-cost=*)   TURN_COST="${1#--turn-cost=}"; shift ;;
    --running-total) RUNNING_TOTAL="${2-}"; shift 2 ;;
    --running-total=*) RUNNING_TOTAL="${1#--running-total=}"; shift ;;
    *)
      echo "turn-header.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

for var in ROUND TURN SPEAKER ROLE TURN_COST RUNNING_TOTAL; do
  if [[ -z "${!var}" ]]; then
    echo "turn-header.sh: --${var,,} is required" >&2
    exit 3
  fi
done

# Numeric fields must be non-negative integers
for numeric in ROUND TURN TURN_COST RUNNING_TOTAL; do
  val="${!numeric}"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "turn-header.sh: --${numeric,,} must be a non-negative integer (got: '$val')" >&2
    exit 3
  fi
done

printf '[round %s / turn %s / %s (%s) / per-turn-cost %s tokens / running-total %s tokens]\n' \
  "$ROUND" "$TURN" "$SPEAKER" "$ROLE" "$TURN_COST" "$RUNNING_TOTAL"

exit 0
