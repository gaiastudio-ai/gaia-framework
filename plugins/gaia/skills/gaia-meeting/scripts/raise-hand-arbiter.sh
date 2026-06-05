#!/usr/bin/env bash
# raise-hand-arbiter.sh — gaia-meeting raise-hand arbitration
#
# Implements:
#   - Detect `[raise-hand → respond to {Name}]` (or ASCII `->`) in agent turn
#       output; plan an insertion that makes the named agent the next speaker;
#       resume the round-robin from the position it would have occupied prior
#       to the insertion.
#   - Enforce ONE raise-hand per turn cycle. Additional raise-hands in the same
#       cycle are deferred to the next cycle and honored as the FIRST action of
#       the next cycle.
#
# State persistence:
#   The per-cycle ledger lives in a small env file at $RAISE_HAND_STATE
#   (default: $TMPDIR/gaia-meeting-raise-hand.env). Each cycle gets at most
#   one HONORED slot; subsequent requests in the same cycle append to a
#   DEFERRED list keyed on the cycle index.
#
# Usage:
#   raise-hand-arbiter.sh --detect "<turn body>"
#   raise-hand-arbiter.sh --plan-insertion --invitees "A,B,C,D" \
#                         --requesting <name> --target <name> --cycle <int>
#   raise-hand-arbiter.sh --record-raise-hand --cycle <int> \
#                         --requesting <name> --target <name>
#   raise-hand-arbiter.sh --pending-deferred --cycle <int>
#   raise-hand-arbiter.sh --log-line --cycle <int> --requesting <name> \
#                         --target <name> --status <honored|deferred-to-next-cycle>
#
# Exit codes:
#   0 = success
#   1 = no raise-hand marker detected (--detect)
#   2 = invalid argument value
#   3 = malformed args / missing input

set -euo pipefail
export LC_ALL=C

STATE_FILE="${RAISE_HAND_STATE:-${TMPDIR:-/tmp}/gaia-meeting-raise-hand.env}"

# --- Detection --------------------------------------------------------------

# Detect `[raise-hand → respond to {Name}]` (em-dash or ASCII '->' arrow).
# Outputs the captured target name on success.
detect_raise_hand() {
  local body="$1"
  # Try em-dash form first.
  local match
  match="$(printf '%s' "$body" | grep -oE '\[raise-hand[[:space:]]*(→|->)[[:space:]]*respond[[:space:]]+to[[:space:]]+[^]]+\]' | head -1)"
  if [[ -z "$match" ]]; then
    return 1
  fi
  # Extract the name between "respond to " and the trailing "]".
  local name
  name="$(printf '%s' "$match" | sed -E 's/.*respond[[:space:]]+to[[:space:]]+([^]]+)\]/\1/' | sed -e 's/[[:space:]]*$//')"
  if [[ -z "$name" ]]; then
    return 1
  fi
  printf '%s\n' "$name"
}

cmd_detect() {
  local body="$1"
  local name
  if name="$(detect_raise_hand "$body")"; then
    printf '%s\n' "$name"
    return 0
  fi
  echo "raise-hand-arbiter.sh: no raise-hand marker detected" >&2
  exit 1
}

# --- Insertion planning -----------------------------------------------------
#
# Given round [A,B,C,D] (CSV in invite order) and a raise-hand from REQUESTING
# to TARGET, produce the speaker sequence for the remainder of the cycle:
#   1. TARGET (inserted)
#   2..N: the round-robin slots that would have followed REQUESTING in normal
#         order, in order, EXCEPT we do NOT skip TARGET — TARGET still appears
#         in its original slot per AC8 ("the round-robin order MUST NOT be
#         permanently shifted by the insertion").
#
# Example: invitees A,B,C,D — current speaker A (just emitted raise-hand).
# Remaining of normal cycle 1 = [B, C, D]. Inserted TARGET=C goes first:
#   C, B, C, D
plan_insertion() {
  local invitees_csv="$1"
  local requesting="$2"
  local target="$3"

  # Parse CSV into array.
  local -a inv_arr
  IFS=',' read -r -a inv_arr <<< "$invitees_csv"
  if [[ ${#inv_arr[@]} -eq 0 ]]; then
    echo "raise-hand-arbiter.sh: --invitees is empty." >&2
    exit 3
  fi

  # Locate REQUESTING.
  local req_idx=-1
  local i=0
  for name in "${inv_arr[@]}"; do
    if [[ "$name" == "$requesting" ]]; then
      req_idx="$i"
      break
    fi
    i=$((i + 1))
  done
  if [[ "$req_idx" -lt 0 ]]; then
    echo "raise-hand-arbiter.sh: requesting agent '$requesting' is not in --invitees." >&2
    exit 2
  fi

  # Locate TARGET — must be in invitees (cannot insert an outsider).
  local tgt_idx=-1
  i=0
  for name in "${inv_arr[@]}"; do
    if [[ "$name" == "$target" ]]; then
      tgt_idx="$i"
      break
    fi
    i=$((i + 1))
  done
  if [[ "$tgt_idx" -lt 0 ]]; then
    echo "raise-hand-arbiter.sh: target agent '$target' is not in --invitees." >&2
    exit 2
  fi

  # Emit TARGET first (inserted).
  printf '%s\n' "$target"

  # Then emit the remaining round-robin starting from the slot AFTER REQUESTING,
  # in the original invite order. The cycle is "single pass through participant
  # list", so we walk slots req_idx+1 .. n-1.
  local n=${#inv_arr[@]}
  local j=$((req_idx + 1))
  while [[ "$j" -lt "$n" ]]; do
    printf '%s\n' "${inv_arr[$j]}"
    j=$((j + 1))
  done
}

# --- State ledger -----------------------------------------------------------
#
# Format on disk (env file):
#   HONORED_<cycle>="<requesting>:<target>"
#   DEFERRED_<cycle>="<req1>:<tgt1>;<req2>:<tgt2>;..."
#
# Cycle indices are positive integers.

ensure_state_file() {
  mkdir -p "$(dirname "$STATE_FILE")"
  if [[ ! -f "$STATE_FILE" ]]; then
    : > "$STATE_FILE"
  fi
}

read_var() {
  local key="$1"
  if [[ ! -f "$STATE_FILE" ]]; then
    return 0
  fi
  # `grep` returns 1 when no match — that's a normal "absent" signal here, not
  # an error. Keep set -e / pipefail safe by short-circuiting via `|| true`.
  local raw
  raw="$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -1 || true)"
  if [[ -z "$raw" ]]; then
    return 0
  fi
  printf '%s' "$raw" | sed -E 's/^[^=]+="?([^"]*)"?$/\1/'
}

write_var() {
  local key="$1"
  local value="$2"
  ensure_state_file
  # Remove any prior entry then append.
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$STATE_FILE" ]]; then
    # grep -v returns 1 when EVERY line matches (so the inverse list is empty);
    # tolerate that under set -e.
    grep -vE "^${key}=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  fi
  printf '%s="%s"\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

cmd_record_raise_hand() {
  local cycle="$1"
  local requesting="$2"
  local target="$3"

  if ! [[ "$cycle" =~ ^[1-9][0-9]*$ ]]; then
    echo "raise-hand-arbiter.sh: --cycle must be a positive integer." >&2
    exit 3
  fi

  local honored_key="HONORED_${cycle}"
  local current
  current="$(read_var "$honored_key")"
  if [[ -z "$current" ]]; then
    write_var "$honored_key" "${requesting}:${target}"
    echo "honored"
    return 0
  fi

  # A raise-hand was already honored this cycle — defer.
  local def_key="DEFERRED_${cycle}"
  local existing
  existing="$(read_var "$def_key")"
  local new_entry="${requesting}:${target}"
  local appended
  if [[ -z "$existing" ]]; then
    appended="$new_entry"
  else
    appended="${existing};${new_entry}"
  fi
  write_var "$def_key" "$appended"
  echo "deferred-to-next-cycle"
}

cmd_pending_deferred() {
  local cycle="$1"
  if ! [[ "$cycle" =~ ^[1-9][0-9]*$ ]]; then
    echo "raise-hand-arbiter.sh: --cycle must be a positive integer." >&2
    exit 3
  fi
  # Pending deferreds for cycle N are those recorded against cycle N-1.
  local prev=$((cycle - 1))
  if [[ "$prev" -lt 1 ]]; then
    return 0
  fi
  local entries
  entries="$(read_var "DEFERRED_${prev}")"
  if [[ -z "$entries" ]]; then
    return 0
  fi
  # Emit entries in the form req->tgt, one per line.
  printf '%s\n' "$entries" | tr ';' '\n' | while IFS=':' read -r r t; do
    [[ -z "${r:-}" ]] && continue
    printf '%s->%s\n' "$r" "$t"
  done
}

cmd_log_line() {
  local cycle="$1"
  local requesting="$2"
  local target="$3"
  local status="$4"
  case "$status" in
    honored|deferred-to-next-cycle) ;;
    *)
      echo "raise-hand-arbiter.sh: --status must be 'honored' or 'deferred-to-next-cycle'." >&2
      exit 3
      ;;
  esac
  printf '[raise-hand cycle=%s requesting=%s target=%s status=%s]\n' \
    "$cycle" "$requesting" "$target" "$status"
}

# --- Argument parsing -------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "raise-hand-arbiter.sh: a subcommand flag is required." >&2
  exit 3
fi

CMD=""
INVITEES=""
REQUESTING=""
TARGET=""
CYCLE=""
STATUS=""
DETECT_BODY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --detect)
      CMD="detect"
      DETECT_BODY="${2-}"
      if [[ $# -lt 2 ]]; then
        echo "raise-hand-arbiter.sh: --detect requires a body argument." >&2
        exit 3
      fi
      shift 2
      ;;
    --plan-insertion)
      CMD="plan-insertion"
      shift
      ;;
    --record-raise-hand)
      CMD="record-raise-hand"
      shift
      ;;
    --pending-deferred)
      CMD="pending-deferred"
      shift
      ;;
    --log-line)
      CMD="log-line"
      shift
      ;;
    --invitees)
      INVITEES="${2-}"; shift 2 ;;
    --invitees=*)
      INVITEES="${1#--invitees=}"; shift ;;
    --requesting)
      REQUESTING="${2-}"; shift 2 ;;
    --requesting=*)
      REQUESTING="${1#--requesting=}"; shift ;;
    --target)
      TARGET="${2-}"; shift 2 ;;
    --target=*)
      TARGET="${1#--target=}"; shift ;;
    --cycle)
      CYCLE="${2-}"; shift 2 ;;
    --cycle=*)
      CYCLE="${1#--cycle=}"; shift ;;
    --status)
      STATUS="${2-}"; shift 2 ;;
    --status=*)
      STATUS="${1#--status=}"; shift ;;
    *)
      echo "raise-hand-arbiter.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

case "$CMD" in
  detect)
    cmd_detect "$DETECT_BODY"
    ;;
  plan-insertion)
    if [[ -z "$INVITEES" || -z "$REQUESTING" || -z "$TARGET" || -z "$CYCLE" ]]; then
      echo "raise-hand-arbiter.sh: --plan-insertion requires --invitees, --requesting, --target, --cycle." >&2
      exit 3
    fi
    plan_insertion "$INVITEES" "$REQUESTING" "$TARGET"
    ;;
  record-raise-hand)
    if [[ -z "$CYCLE" || -z "$REQUESTING" || -z "$TARGET" ]]; then
      echo "raise-hand-arbiter.sh: --record-raise-hand requires --cycle, --requesting, --target." >&2
      exit 3
    fi
    cmd_record_raise_hand "$CYCLE" "$REQUESTING" "$TARGET"
    ;;
  pending-deferred)
    if [[ -z "$CYCLE" ]]; then
      echo "raise-hand-arbiter.sh: --pending-deferred requires --cycle." >&2
      exit 3
    fi
    cmd_pending_deferred "$CYCLE"
    ;;
  log-line)
    if [[ -z "$CYCLE" || -z "$REQUESTING" || -z "$TARGET" || -z "$STATUS" ]]; then
      echo "raise-hand-arbiter.sh: --log-line requires --cycle, --requesting, --target, --status." >&2
      exit 3
    fi
    cmd_log_line "$CYCLE" "$REQUESTING" "$TARGET" "$STATUS"
    ;;
  *)
    echo "raise-hand-arbiter.sh: no recognized subcommand was provided." >&2
    exit 3
    ;;
esac
