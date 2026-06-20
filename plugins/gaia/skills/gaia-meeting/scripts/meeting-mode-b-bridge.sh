#!/usr/bin/env bash
# meeting-mode-b-bridge.sh — Mode B meeting bridge library.
# Sourceable, NOT executable.
#
# Bridges the gaia-meeting 7-phase lifecycle to the shared Mode B
# dispatch-teammate library. Meeting-specific concerns:
#   - Per-participant spawn with session context
#   - Interjection routing to active teammates
#   - Action-items formatting (structurally identical to Mode A)
#   - Transcript relay (delegates to relay_to_team_lead)
#
# The library degrades to Mode A foreground fallback when the substrate
# is absent (dispatch-teammate handles the fallback + MODE_B_FALLBACK
# token emission).

# ---------- Source guard ----------

if [ "${_MMB_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Dependency: dispatch-teammate.sh ----------

_MMB_DT_LIB=""

_mmb_ensure_dt() {
  if [ -z "$_MMB_DT_LIB" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib" && pwd)"
    _MMB_DT_LIB="$lib_dir/dispatch-teammate.sh"
  fi
  if [ "${_DT_LOADED:-0}" != "1" ]; then
    # shellcheck source=/dev/null
    . "$_MMB_DT_LIB"
  fi
}

# ---------- Internal state ----------

# Last-active teammate handle — updated on each drive_turn relay cycle.
_MMB_LAST_ACTIVE_HANDLE=""

# Map of persona-slug to handle (simple flat file under session dir).
_MMB_PARTICIPANT_MAP=""

_mmb_participant_map_path() {
  local dir="${GAIA_SESSION_DIR:?GAIA_SESSION_DIR must be set}"
  _MMB_PARTICIPANT_MAP="$dir/participant-map.txt"
  printf '%s' "$_MMB_PARTICIPANT_MAP"
}

# _mmb_register_participant HANDLE PERSONA — record persona-to-handle mapping.
_mmb_register_participant() {
  local handle="$1"
  local persona="$2"
  local map_path
  map_path="$(_mmb_participant_map_path)"
  # Normalise persona — strip gaia: prefix, lowercase.
  local slug
  slug="$(printf '%s' "$persona" | sed 's/^gaia://' | tr '[:upper:]' '[:lower:]')"
  printf '%s\t%s\n' "$slug" "$handle" >> "$map_path"
}

# _mmb_lookup_participant PERSONA_SLUG — find handle by persona slug.
_mmb_lookup_participant() {
  local slug="$1"
  slug="$(printf '%s' "$slug" | sed 's/^gaia://' | tr '[:upper:]' '[:lower:]')"
  local map_path
  map_path="$(_mmb_participant_map_path)"
  if [ -f "$map_path" ]; then
    awk -F'\t' -v s="$slug" '$1 == s { print $2; exit }' "$map_path"
  fi
}

# ---------- Public API ----------

# meeting_spawn_participant PERSONA SESSION_ID [--context CTX]
# Spawn a meeting participant via spawn_teammate.
# Returns the handle on stdout.
meeting_spawn_participant() {
  local persona="${1:-}"
  local session_id="${2:-}"

  _mmb_ensure_dt

  if [ -z "$persona" ]; then
    printf 'meeting-mode-b-bridge: persona is required\n' >&2
    return 1
  fi

  local handle
  handle="$(spawn_teammate "$persona" --context "meeting:${session_id:-unknown}")"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  _mmb_register_participant "$handle" "$persona"

  printf '%s\n' "$handle"
}

# meeting_route_interjection [--to PERSONA] [TEXT]
# Route a human interjection to the correct active teammate.
# Without --to, routes to the last-active teammate.
# Returns the target handle on stdout (empty if none).
meeting_route_interjection() {
  local target_persona=""

  _mmb_ensure_dt

  while [ $# -gt 0 ]; do
    case "$1" in
      --to)
        target_persona="${2:-}"
        shift 2
        ;;
      *)
        # Interjection text — consumed by the caller, not by routing logic.
        shift
        ;;
    esac
  done

  if [ -n "$target_persona" ]; then
    # Route to a named participant.
    local handle
    handle="$(_mmb_lookup_participant "$target_persona")"
    if [ -n "$handle" ]; then
      printf '%s\n' "$handle"
      return 0
    fi
    printf 'meeting-mode-b-bridge: no active teammate for persona "%s"\n' "$target_persona" >&2
    return 1
  fi

  # Default: route to the last-active teammate.
  if [ -n "$_MMB_LAST_ACTIVE_HANDLE" ]; then
    _dt_ensure_registry
    if [ -f "$_DT_REGISTRY_DIR/$_MMB_LAST_ACTIVE_HANDLE" ]; then
      printf '%s\n' "$_MMB_LAST_ACTIVE_HANDLE"
      return 0
    fi
  fi

  # No active teammate.
  return 0
}

# meeting_format_action_items (DESC ASSIGNEE DUE_DATE)+
# Format action items in the canonical YAML shape identical to Mode A.
# Takes triples of (description, assignee, due_date) as positional args.
meeting_format_action_items() {
  local args=("$@")
  local count=${#args[@]}
  local i=0

  while [ "$i" -lt "$count" ]; do
    local desc="${args[$i]:-}"
    local assignee="${args[$((i + 1))]:-}"
    local due_date="${args[$((i + 2))]:-}"
    printf '  - description: %s\n' "$desc"
    printf '    assignee: %s\n' "$assignee"
    printf '    due_date: %s\n' "$due_date"
    i=$((i + 3))
  done
}

# Override: track last-active on relay. We wrap relay_to_team_lead with
# a post-hook that updates the last-active handle. The actual relay is
# handled by dispatch-teammate.sh — we just need the tracking state.
#
# This is done via a wrapper that the meeting lifecycle should call
# instead of raw relay_to_team_lead when it wants interjection tracking.
meeting_relay_turn() {
  local handle="${1:-}"
  local payload="${2:-}"

  _mmb_ensure_dt

  # Update last-active before relay.
  _MMB_LAST_ACTIVE_HANDLE="$handle"

  relay_to_team_lead "$handle" "$payload"
}

# ---------- Source guard — mark loaded ----------
_MMB_LOADED=1
