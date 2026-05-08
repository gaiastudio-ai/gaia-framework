#!/usr/bin/env bash
# per-agent-cap.sh — gaia-meeting per-agent token cap accountant (E76-S6, AC5)
#
# FR-MTG-29 / TC-MTG-GUARD-3: default per-agent cap = 25 000 tokens, cumulative
# across research, discussion, raise-hand, and research interrupts. On cap
# cross, the agent is muted (one-way — no unmute path within a single meeting),
# a single MUTED event is emitted, and the orchestrator continues with the
# remaining non-muted agents.
#
# State file format (one record per agent, two lines per record):
#   agent=<id>|tokens=<N>|muted=<0|1>
#
# Usage:
#   per-agent-cap.sh --state <file> --accumulate --agent <id> --tokens <N> [--per-agent-cap CAP]
#   per-agent-cap.sh --state <file> --get --agent <id>
#   per-agent-cap.sh --state <file> --is-muted --agent <id>
#
# Exit codes:
#   0 = success (or, for --is-muted, agent IS muted)
#   1 = (--is-muted only) agent is NOT muted
#   3 = malformed args

set -euo pipefail

DEFAULT_CAP=25000
STATE=""
ACCUMULATE=0
GET=0
IS_MUTED=0
UNMUTE=0
AGENT=""
TOKENS=""
PER_AGENT_CAP="$DEFAULT_CAP"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)            STATE="${2-}"; shift 2 ;;
    --state=*)          STATE="${1#--state=}"; shift ;;
    --accumulate)       ACCUMULATE=1; shift ;;
    --get)              GET=1; shift ;;
    --is-muted)         IS_MUTED=1; shift ;;
    --unmute)           UNMUTE=1; shift ;;
    --agent)            AGENT="${2-}"; shift 2 ;;
    --agent=*)          AGENT="${1#--agent=}"; shift ;;
    --tokens)           TOKENS="${2-}"; shift 2 ;;
    --tokens=*)         TOKENS="${1#--tokens=}"; shift ;;
    --per-agent-cap)    PER_AGENT_CAP="${2-}"; shift 2 ;;
    --per-agent-cap=*)  PER_AGENT_CAP="${1#--per-agent-cap=}"; shift ;;
    *)
      echo "per-agent-cap.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$STATE" ]]; then
  echo "per-agent-cap.sh: --state is required" >&2
  exit 3
fi
if [[ -z "$AGENT" ]]; then
  echo "per-agent-cap.sh: --agent is required" >&2
  exit 3
fi

# Muting is one-way — refuse --unmute outright (rationale: cap exists to bound spend).
if [[ "$UNMUTE" -eq 1 ]]; then
  echo "per-agent-cap.sh: --unmute is forbidden — muting is one-way per AC5 (FR-MTG-29)" >&2
  exit 3
fi

# Initialize state file if absent.
if [[ ! -f "$STATE" ]]; then
  : > "$STATE"
fi

# Read current record for the agent.
read_record() {
  local agent="$1"
  local line
  line="$(grep -E "^agent=${agent}\|" "$STATE" 2>/dev/null || true)"
  if [[ -z "$line" ]]; then
    echo "0|0"
    return 0
  fi
  local tokens muted
  tokens="$(printf '%s' "$line" | sed -E 's/^.*\|tokens=([0-9]+)\|.*$/\1/')"
  muted="$(printf '%s' "$line" | sed -E 's/^.*\|muted=([01])$/\1/')"
  echo "${tokens}|${muted}"
}

write_record() {
  local agent="$1" tokens="$2" muted="$3"
  # Drop any prior record, then append the new one.
  if grep -qE "^agent=${agent}\|" "$STATE" 2>/dev/null; then
    grep -vE "^agent=${agent}\|" "$STATE" > "$STATE.tmp" || true
    mv "$STATE.tmp" "$STATE"
  fi
  printf 'agent=%s|tokens=%s|muted=%s\n' "$agent" "$tokens" "$muted" >> "$STATE"
}

if [[ "$GET" -eq 1 ]]; then
  rec="$(read_record "$AGENT")"
  echo "${rec%%|*}"
  exit 0
fi

if [[ "$IS_MUTED" -eq 1 ]]; then
  rec="$(read_record "$AGENT")"
  muted_flag="${rec##*|}"
  if [[ "$muted_flag" == "1" ]]; then
    exit 0
  fi
  exit 1
fi

if [[ "$ACCUMULATE" -eq 1 ]]; then
  if ! [[ "$TOKENS" =~ ^[0-9]+$ ]]; then
    echo "per-agent-cap.sh: --tokens must be a non-negative integer (got: '$TOKENS')" >&2
    exit 3
  fi
  if ! [[ "$PER_AGENT_CAP" =~ ^[1-9][0-9]*$ ]]; then
    echo "per-agent-cap.sh: --per-agent-cap must be a positive integer (got: '$PER_AGENT_CAP')" >&2
    exit 3
  fi
  rec="$(read_record "$AGENT")"
  current_tokens="${rec%%|*}"
  current_muted="${rec##*|}"
  new_tokens=$((current_tokens + TOKENS))
  if [[ "$current_muted" == "1" ]]; then
    # Already muted — accumulate but do not re-emit MUTED.
    write_record "$AGENT" "$new_tokens" "1"
    exit 0
  fi
  if [[ "$new_tokens" -ge "$PER_AGENT_CAP" ]]; then
    write_record "$AGENT" "$new_tokens" "1"
    echo "MUTED agent=$AGENT tokens=$new_tokens cap=$PER_AGENT_CAP fr=FR-MTG-29"
    exit 0
  fi
  write_record "$AGENT" "$new_tokens" "0"
  exit 0
fi

echo "per-agent-cap.sh: a subcommand is required (--accumulate / --get / --is-muted)" >&2
exit 3
