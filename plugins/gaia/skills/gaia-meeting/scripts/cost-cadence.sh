#!/usr/bin/env bash
# cost-cadence.sh — gaia-meeting deterministic cost-check cadence
#
# A single global emitted-turn counter that increments after every
# transcript-append (round-robin, prelude, raise-hand, research-interrupt,
# user-interjection, facilitator). The cost-check fires whenever
# counter % 10 == 0 — independent of which KIND of turn was emitted.
# This is the determinism contract that lets raise-hand insertions remain
# deterministic against the same cadence: a 30-turn meeting fires cost checks
# at emitted-turn indices 10, 20, 30 regardless of how many of those turns are
# raise-hand interrupts.
#
# State file format — one line:
#   counter=<N>
#
# Usage:
#   cost-cadence.sh --state <file> --tick
#   cost-cadence.sh --state <file> --get
#   cost-cadence.sh --state <file> --should-fire
#
# Exit codes:
#   0 = success / counter at a multiple of 10 (--should-fire)
#   1 = (--should-fire) counter NOT at a multiple of 10
#   3 = malformed args

set -euo pipefail

STATE=""
TICK=0
GET=0
SHOULD_FIRE=0
CADENCE=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)         STATE="${2-}"; shift 2 ;;
    --state=*)       STATE="${1#--state=}"; shift ;;
    --tick)          TICK=1; shift ;;
    --get)           GET=1; shift ;;
    --should-fire)   SHOULD_FIRE=1; shift ;;
    --cadence)       CADENCE="${2-}"; shift 2 ;;
    --cadence=*)     CADENCE="${1#--cadence=}"; shift ;;
    *)
      echo "cost-cadence.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$STATE" ]]; then
  echo "cost-cadence.sh: --state is required" >&2
  exit 3
fi
if ! [[ "$CADENCE" =~ ^[1-9][0-9]*$ ]]; then
  echo "cost-cadence.sh: --cadence must be a positive integer" >&2
  exit 3
fi

# Read current counter (defaults to 0).
read_counter() {
  if [[ -f "$STATE" ]]; then
    local line
    line="$(grep -E '^counter=' "$STATE" 2>/dev/null | head -1)"
    if [[ -n "$line" ]]; then
      printf '%s' "${line#counter=}"
      return 0
    fi
  fi
  printf '0'
}

if [[ "$GET" -eq 1 ]]; then
  read_counter
  echo ""
  exit 0
fi

if [[ "$TICK" -eq 1 ]]; then
  current="$(read_counter)"
  next=$((current + 1))
  printf 'counter=%s\n' "$next" > "$STATE"
  echo "$next"
  exit 0
fi

if [[ "$SHOULD_FIRE" -eq 1 ]]; then
  current="$(read_counter)"
  if [[ "$current" -gt 0 ]] && [[ $((current % CADENCE)) -eq 0 ]]; then
    exit 0
  fi
  exit 1
fi

echo "cost-cadence.sh: a subcommand is required (--tick / --get / --should-fire)" >&2
exit 3
