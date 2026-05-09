#!/usr/bin/env bash
# session-state.sh — gaia-meeting session-state helper (E76-S7, AC1, FR-MTG-33)
#
# Round-trips the FR-MTG-33 schema into a YAML file under
# `_memory/meeting-sessions/{YYYY-MM-DD}-{slug}.yaml`. Treated as a flat
# key/value store so we can avoid pulling in yq as a hard dependency — any
# YAML parser still reads it correctly.
#
# Usage:
#   session-state.sh create --file <path> --session-id <id>
#   session-state.sh read   --file <path> --field <name>
#   session-state.sh update --file <path> --field <name> --value <value>
#
# Exit codes:
#   0 = success
#   2 = malformed args / unknown field / file not found
#   3 = atomic-write failure (parent missing, mv failed)

set -euo pipefail

SUBCOMMAND="${1-}"
shift || true

FILE=""
FIELD=""
VALUE=""
SESSION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)        FILE="${2-}"; shift 2 ;;
    --field)       FIELD="${2-}"; shift 2 ;;
    --value)       VALUE="${2-}"; shift 2 ;;
    --session-id)  SESSION_ID="${2-}"; shift 2 ;;
    *)
      echo "session-state.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$FILE" ]]; then
  echo "session-state.sh: --file is required" >&2
  exit 2
fi

# FR-MTG-33 schema — canonical order. Keep this list in sync with PRD §4.39.11
# and SKILL.md "Session-state schema (FR-MTG-33)".
#
# `last_yield_emitted_at` was added by E76-S9 (AC2) so `yield-gate.sh` can
# stamp the most-recent yield emission for `--resume` consistency. The new
# field is opaque to existing consumers and does NOT change the call signature
# of the create / read / update API — see E76-S9 Tech Notes.
FIELDS=(
  session_id
  phase
  round
  turn_counter
  cadence_counter
  raise_hand_ledger
  scratchpad_state
  cumulative_cost
  last_checkpoint_at
  last_checkpoint_phase
  last_yield_emitted_at
  agent_dispatch_findings
)

is_valid_field() {
  local f="$1"
  for known in "${FIELDS[@]}"; do
    [[ "$f" == "$known" ]] && return 0
  done
  return 1
}

# Quote the value for YAML — strings get double-quotes, integers stay bare.
yaml_emit_value() {
  local field="$1"; local v="$2"
  case "$field" in
    round|turn_counter|cadence_counter|cumulative_cost)
      printf '%s' "$v"
      ;;
    *)
      # Escape any embedded double quotes.
      local escaped="${v//\"/\\\"}"
      printf '"%s"' "$escaped"
      ;;
  esac
}

write_default_yaml() {
  local out="$1"
  cat > "$out" <<EOF
session_id: $(yaml_emit_value session_id "$SESSION_ID")
phase: $(yaml_emit_value phase "INVITE")
round: 0
turn_counter: 0
cadence_counter: 0
raise_hand_ledger: $(yaml_emit_value raise_hand_ledger "")
scratchpad_state: $(yaml_emit_value scratchpad_state "")
cumulative_cost: 0
last_checkpoint_at: $(yaml_emit_value last_checkpoint_at "")
last_checkpoint_phase: $(yaml_emit_value last_checkpoint_phase "")
last_yield_emitted_at: $(yaml_emit_value last_yield_emitted_at "")
agent_dispatch_findings: $(yaml_emit_value agent_dispatch_findings "")
EOF
}

atomic_write() {
  local target="$1"
  local payload_fn="$2"
  local parent
  parent="$(dirname "$target")"
  if [[ ! -d "$parent" ]]; then
    echo "session-state.sh: parent directory does not exist: $parent" >&2
    exit 3
  fi
  local tmp
  tmp="$(mktemp "${parent}/.session-state.XXXXXX")"
  # On any failure between here and mv, remove the tmp file.
  trap 'rm -f "$tmp"' EXIT
  "$payload_fn" "$tmp"
  mv "$tmp" "$target"
  trap - EXIT
}

case "$SUBCOMMAND" in
  create)
    if [[ -z "$SESSION_ID" ]]; then
      echo "session-state.sh: create requires --session-id" >&2
      exit 2
    fi
    atomic_write "$FILE" write_default_yaml
    exit 0
    ;;

  read)
    if [[ -z "$FIELD" ]]; then
      echo "session-state.sh: read requires --field" >&2
      exit 2
    fi
    if [[ ! -f "$FILE" ]]; then
      echo "session-state.sh: file not found: $FILE" >&2
      exit 2
    fi
    if ! is_valid_field "$FIELD"; then
      echo "session-state.sh: unknown field: $FIELD" >&2
      exit 2
    fi
    line="$(grep -E "^${FIELD}: " "$FILE" || true)"
    if [[ -z "$line" ]]; then
      # Field absent — treat as empty string.
      printf '\n'
      exit 0
    fi
    raw="${line#${FIELD}: }"
    # Strip surrounding double quotes if present.
    if [[ "$raw" == \"*\" ]]; then
      raw="${raw#\"}"
      raw="${raw%\"}"
      # Unescape embedded quotes.
      raw="${raw//\\\"/\"}"
    fi
    printf '%s\n' "$raw"
    exit 0
    ;;

  update)
    if [[ -z "$FIELD" ]]; then
      echo "session-state.sh: update requires --field" >&2
      exit 2
    fi
    if [[ ! -f "$FILE" ]]; then
      echo "session-state.sh: file not found: $FILE" >&2
      exit 2
    fi
    if ! is_valid_field "$FIELD"; then
      echo "session-state.sh: unknown field: $FIELD" >&2
      exit 2
    fi
    new_value="$(yaml_emit_value "$FIELD" "$VALUE")"
    payload_fn() {
      local out="$1"
      # Write all known fields, replacing the matched one with the new value.
      while IFS= read -r line; do
        local key="${line%%: *}"
        if [[ "$key" == "$FIELD" ]]; then
          printf '%s: %s\n' "$FIELD" "$new_value"
        else
          printf '%s\n' "$line"
        fi
      done < "$FILE" > "$out"
    }
    atomic_write "$FILE" payload_fn
    exit 0
    ;;

  *)
    echo "session-state.sh: usage: session-state.sh <create|read|update> --file <path> [--field NAME --value VALUE | --session-id ID]" >&2
    exit 2
    ;;
esac
