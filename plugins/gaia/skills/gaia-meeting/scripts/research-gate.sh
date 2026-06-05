#!/usr/bin/env bash
# research-gate.sh — gaia-meeting research-phase completeness gate
#
# Phase-transition gate from RESEARCH to DISCUSS. Requires one structured
# prelude per invited agent before discussion can begin.
# Bypasses only on --skip-research (explicit user opt-out).
#
# On halt, emits a single canonical HALT event via halt-event.sh and refuses
# phase advancement — the persisted transcript MUST NOT contain any
# discussion-phase turns.
#
# Usage:
#   research-gate.sh --invitees "theo,derek" --preludes-file <path> [--skip-research]
#
# The preludes file lists one agent identifier per line — the set of agents
# that produced a structured prelude during the research phase.
#
# Exit codes:
#   0 = gate passes (preludes present for every invitee, OR --skip-research)
#   2 = HALT (one or more preludes missing) — halt event on stdout
#   3 = malformed args

set -euo pipefail

INVITEES=""
PRELUDES_FILE=""
SKIP_RESEARCH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --invitees)         INVITEES="${2-}"; shift 2 ;;
    --invitees=*)       INVITEES="${1#--invitees=}"; shift ;;
    --preludes-file)    PRELUDES_FILE="${2-}"; shift 2 ;;
    --preludes-file=*)  PRELUDES_FILE="${1#--preludes-file=}"; shift ;;
    --skip-research)    SKIP_RESEARCH=1; shift ;;
    *)
      echo "research-gate.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$INVITEES" ]]; then
  echo "research-gate.sh: --invitees is required (non-empty CSV)" >&2
  exit 3
fi

# --skip-research bypasses the gate entirely (explicit user opt-out).
if [[ "$SKIP_RESEARCH" -eq 1 ]]; then
  echo "research-gate.sh: --skip-research bypass — gate passed without prelude check"
  exit 0
fi

# Build the set of agents that produced a prelude.
prelude_set=""
if [[ -f "$PRELUDES_FILE" ]]; then
  prelude_set="$(tr -d '\r' < "$PRELUDES_FILE" | sort -u)"
fi

# Verify every invitee has a prelude.
missing=()
IFS=',' read -r -a invitee_arr <<< "$INVITEES"
for raw in "${invitee_arr[@]}"; do
  agent="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$agent" ]] && continue
  if ! printf '%s\n' "$prelude_set" | grep -Fxq "$agent"; then
    missing+=("$agent")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "research-gate.sh: PASS — prelude present for every invitee"
  exit 0
fi

# Halt — emit canonical halt event.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
detail="missing preludes for: $(IFS=,; echo "${missing[*]}")"
"$SCRIPT_DIR/halt-event.sh" \
  --condition RESEARCH-MISSING \
  --fr FR-MTG-28 \
  --detail "$detail"
exit 2
