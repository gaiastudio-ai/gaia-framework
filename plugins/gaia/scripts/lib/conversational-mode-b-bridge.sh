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
#
# ROUND-TRIP CONTRACT. This bridge does bookkeeping ONLY. The actual per-turn
# teammate round-trip — the orchestrator emitting a real SendMessage with the
# mandatory reply-routing reminder, the teammate replying via
# SendMessage(to: team-lead), and the relay back to the transcript — is driven
# by the skill orchestrator, not by these functions (bash cannot emit
# SendMessage). Callers MUST drive each turn per the canonical contract at
# knowledge/mode-b-round-trip-contract.md. conversational_spawn_participant /
# conversational_relay_turn / conversational_shutdown are the bookkeeping seams
# that contract references.

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
  # Warm the ceiling cache in the PARENT shell. Each spawn runs inside a command
  # substitution, so a resolve performed there dies with the subshell and the
  # next spawn re-forks the reader. Resolving once here exports the cache into
  # every later subshell — one read per session instead of one per spawn.
  if [ -z "${_DT_MAX_TEAMMATES:-}" ]; then
    _dt_resolve_ceiling 2>/dev/null || true
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

  # Two rules govern this capture, and both are load-bearing:
  #   - declaration and assignment stay separate, because `local h="$(...)"`
  #     would make the next $? the status of `local` itself, not the spawn's;
  #   - `set -e` is lifted across the assignment, because a failing command
  #     substitution otherwise terminates this function at the assignment and
  #     the status is never inspected at all. A saturated ceiling returns a
  #     non-zero code as a NORMAL capacity outcome, so it must be caught here
  #     rather than killing the skill.
  # This is a sourced library, so shell options are the CALLER's: the lift must
  # be restored to whatever the caller had, never switched on unconditionally.
  local errexit_was_set=0
  case "$-" in *e*) errexit_was_set=1 ;; esac

  local handle
  set +e
  handle="$(spawn_teammate "$persona" --context "conversational:${session_id}")"
  local rc=$?
  if [ "$errexit_was_set" -eq 1 ]; then set -e; fi

  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq "${_DT_CEILING_EXIT_CODE:-8}" ]; then
      printf 'conversational-mode-b-bridge: teammate ceiling saturated, queued for retry\n' >&2
    fi
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
