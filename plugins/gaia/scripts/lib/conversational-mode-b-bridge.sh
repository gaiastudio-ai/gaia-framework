#!/usr/bin/env bash
# conversational-mode-b-bridge.sh — shared Mode B bridge for conversational skills.
# Sourceable, NOT executable.
#
# Bridges the conversational skills (party, brainstorm, brainstorming,
# creative-sprint, design-thinking, problem-solving, retro) to the shared
# Mode B dispatch-teammate library. Conversational skills share one dispatch
# shape: spawn a participant per persona, drive turns, relay output to the
# session transcript, and shut every participant down at skill completion.
#
# The bridge keeps the per-skill SKILL.md prose thin — each skill names this
# bridge as its Mode B participant-dispatch seam and routes spawns through
# conversational_spawn_participant. The shared library degrades to Mode A
# foreground fallback when the substrate is absent (it handles the fallback
# and the MODE_B_FALLBACK token emission), so existing Mode A behavior is
# preserved untouched.

# ---------- Source guard ----------

if [ "${_CMB_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Dependency: dispatch-teammate.sh ----------

_CMB_DT_LIB=""

_cmb_ensure_dt() {
  if [ -z "$_CMB_DT_LIB" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _CMB_DT_LIB="$lib_dir/dispatch-teammate.sh"
  fi
  if [ "${_DT_LOADED:-0}" != "1" ]; then
    # shellcheck source=/dev/null
    . "$_CMB_DT_LIB"
  fi
}

# ---------- Public API ----------

# conversational_spawn_participant PERSONA [SESSION_ID]
# Spawn a conversational participant via spawn_teammate from the shared
# library. Returns the handle on stdout. The clean-room gate, ceiling check,
# provenance log, and MODE_B_FALLBACK emission are all handled inside the
# shared library — this seam keeps a single, uniform call shape for every
# conversational skill.
conversational_spawn_participant() {
  local persona="${1:-}"
  local session_id="${2:-unknown}"

  _cmb_ensure_dt

  if [ -z "$persona" ]; then
    printf 'conversational-mode-b-bridge: persona is required\n' >&2
    return 1
  fi

  local handle
  handle="$(spawn_teammate "$persona" --context "conversational:${session_id}")"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  printf '%s\n' "$handle"
}

# conversational_relay_turn HANDLE OUTPUT
# Relay a participant's turn output to the session transcript via the shared
# library. The transcript shape (and therefore the synthesised artifact) is
# identical to Mode A.
conversational_relay_turn() {
  local handle="${1:-}"
  local payload="${2:-}"

  _cmb_ensure_dt

  relay_to_team_lead "$handle" "$payload"
}

# conversational_shutdown
# Shut down every spawned participant at skill completion. Delegates to
# shutdown_all from the shared library so no teammate is left orphaned.
# Wire this via `trap conversational_shutdown EXIT` in the skill body.
conversational_shutdown() {
  _cmb_ensure_dt

  shutdown_all
}

# ---------- Source guard — mark loaded ----------
_CMB_LOADED=1
