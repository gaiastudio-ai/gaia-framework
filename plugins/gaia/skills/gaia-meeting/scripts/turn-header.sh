#!/usr/bin/env bash
# turn-header.sh — gaia-meeting per-turn header renderer (E76-S1, E76-S10, FR-MTG-10, NFR-MTG-1)
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
# When --phase and --dispatched-via are supplied (E76-S10), the renderer also
# emits the multiline provenance footer:
#   Phase: <PHASE>
#   Turn: <ID>             (only when --turn-id provided)
#   dispatched_via: <subagent|interject|charter>
#
# E76-S10 / AC3 — phase-conditional requirement:
#   For --phase RESEARCH or --phase DISCUSS, --dispatched-via is REQUIRED;
#   missing -> exit 2.
#   For --phase CHARTER / INVITE / CLOSE / SAVE (or absent --phase), missing
#   --dispatched-via emits a one-sprint grace WARNING on stderr and proceeds.
#
# Usage:
#   turn-header.sh --round 1 --turn 1 --speaker "Theo" --role "Architect" \
#                  --turn-cost 100 --running-total 100 \
#                  [--phase RESEARCH|DISCUSS|CHARTER|INVITE|CLOSE|SAVE] \
#                  [--turn-id <id>] \
#                  [--dispatched-via subagent|interject|charter]
#
# Exit codes:
#   0 = header emitted
#   2 = missing --dispatched-via on RESEARCH/DISCUSS phase, or invalid value
#   3 = malformed args

set -euo pipefail
export LC_ALL=C

ROUND=""
TURN=""
SPEAKER=""
ROLE=""
TURN_COST=""
RUNNING_TOTAL=""
PHASE=""
TURN_ID=""
DISPATCHED_VIA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --round)             ROUND="${2-}"; shift 2 ;;
    --round=*)           ROUND="${1#--round=}"; shift ;;
    --turn)              TURN="${2-}"; shift 2 ;;
    --turn=*)            TURN="${1#--turn=}"; shift ;;
    --speaker)           SPEAKER="${2-}"; shift 2 ;;
    --speaker=*)         SPEAKER="${1#--speaker=}"; shift ;;
    --role)              ROLE="${2-}"; shift 2 ;;
    --role=*)            ROLE="${1#--role=}"; shift ;;
    --turn-cost)         TURN_COST="${2-}"; shift 2 ;;
    --turn-cost=*)       TURN_COST="${1#--turn-cost=}"; shift ;;
    --running-total)     RUNNING_TOTAL="${2-}"; shift 2 ;;
    --running-total=*)   RUNNING_TOTAL="${1#--running-total=}"; shift ;;
    --phase)             PHASE="${2-}"; shift 2 ;;
    --phase=*)           PHASE="${1#--phase=}"; shift ;;
    --turn-id)           TURN_ID="${2-}"; shift 2 ;;
    --turn-id=*)         TURN_ID="${1#--turn-id=}"; shift ;;
    --dispatched-via)    DISPATCHED_VIA="${2-}"; shift 2 ;;
    --dispatched-via=*)  DISPATCHED_VIA="${1#--dispatched-via=}"; shift ;;
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

# E76-S10 / AC3 — --dispatched-via enum validation + phase-conditional requirement.
PHASE_UPPER=""
if [[ -n "$PHASE" ]]; then
  # Normalize for matching; emit verbatim original below.
  PHASE_UPPER="$(printf '%s' "$PHASE" | tr '[:lower:]' '[:upper:]')"
fi

if [[ -n "$DISPATCHED_VIA" ]]; then
  case "$DISPATCHED_VIA" in
    subagent|interject|charter) ;;
    *)
      echo "turn-header.sh: --dispatched-via must be one of: subagent, interject, charter (got: '$DISPATCHED_VIA')" >&2
      exit 2
      ;;
  esac
fi

if [[ "$PHASE_UPPER" == "RESEARCH" || "$PHASE_UPPER" == "DISCUSS" ]]; then
  if [[ -z "$DISPATCHED_VIA" ]]; then
    echo "turn-header.sh: --dispatched-via is required for phase '$PHASE' (one of: subagent, interject, charter)" >&2
    exit 2
  fi
elif [[ -n "$PHASE_UPPER" ]]; then
  # Backward-compat: phase is set to CHARTER/INVITE/CLOSE/SAVE, missing
  # --dispatched-via gets a one-sprint grace WARNING and we proceed (ADR-067).
  if [[ -z "$DISPATCHED_VIA" ]]; then
    echo "WARNING: turn-header.sh called without --dispatched-via — required from sprint-41" >&2
  fi
fi
# Legacy invocations with NO --phase argument proceed silently — those call
# sites pre-date E76-S10 and the migration of existing CHARTER/INVITE/CLOSE/
# SAVE call sites (T3.4) is responsible for adding both --phase and
# --dispatched-via together.

# Render the canonical bracketed header line first (NFR-MTG-1 stable contract).
printf '[round %s / turn %s / %s (%s) / per-turn-cost %s tokens / running-total %s tokens]\n' \
  "$ROUND" "$TURN" "$SPEAKER" "$ROLE" "$TURN_COST" "$RUNNING_TOTAL"

# E76-S10 — provenance footer when phase / turn-id / dispatched_via are present.
if [[ -n "$PHASE" ]]; then
  printf 'Phase: %s\n' "$PHASE_UPPER"
fi
if [[ -n "$TURN_ID" ]]; then
  printf 'Turn: %s\n' "$TURN_ID"
fi
if [[ -n "$DISPATCHED_VIA" ]]; then
  printf 'dispatched_via: %s\n' "$DISPATCHED_VIA"
fi

exit 0
