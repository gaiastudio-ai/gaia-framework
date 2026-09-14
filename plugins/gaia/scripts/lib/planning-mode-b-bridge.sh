#!/usr/bin/env bash
# planning-mode-b-bridge.sh — Mode B planning-lifecycle bridge library.
# Sourceable, NOT executable.
#
# Bridges the planning-lifecycle skills (create-prd, create-arch,
# create-epics, create-ux, create-story, product-brief, edit-prd,
# edit-arch, edit-ux, edit-test-plan) to the shared Mode B
# dispatch-teammate library. Planning-specific concerns:
#   - Spawn the authoring subagent (pm / architect / ux-designer /
#     analyst / test-architect) as a persistent teammate.
#   - Relay each authoring turn back to the team lead (transcript parity
#     with the Mode A subagent-dispatch path).
#   - Shut every teammate down at skill exit (no leaked panes).
#
# The library degrades to Mode A foreground fallback when the substrate
# is absent (dispatch-teammate handles the fallback + MODE_B_FALLBACK
# token emission). The planning artifact structure is identical between
# modes: only the dispatch seam changes, never the authored output shape.
#
# ROUND-TRIP CONTRACT. This bridge does bookkeeping ONLY. The actual per-turn
# teammate round-trip — the orchestrator emitting a real SendMessage with the
# mandatory reply-routing reminder, the teammate replying via
# SendMessage(to: team-lead), and the relay back to the transcript — is driven
# by the skill orchestrator, not by these functions (bash cannot emit
# SendMessage). Callers MUST drive each authoring turn per the canonical
# contract at knowledge/mode-b-round-trip-contract.md. planning_spawn_subagent
# / planning_relay_turn / planning_shutdown are the bookkeeping seams that
# contract references.

# ---------- Source guard ----------

if [ "${_PMB_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Dependency: dispatch-teammate.sh ----------

_PMB_DT_LIB=""

_pmb_ensure_dt() {
  if [ -z "$_PMB_DT_LIB" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _PMB_DT_LIB="$lib_dir/dispatch-teammate.sh"
  fi
  if [ "${_DT_LOADED:-0}" != "1" ]; then
    # shellcheck source=/dev/null
    . "$_PMB_DT_LIB"
  fi
  # Warm the ceiling cache in the PARENT shell. Each spawn runs inside a command
  # substitution, so a resolve performed there dies with the subshell and the
  # next spawn re-forks the reader. Resolving once here exports the cache into
  # every later subshell — one read per session instead of one per spawn.
  if [ -z "${_DT_MAX_TEAMMATES:-}" ]; then
    _dt_resolve_ceiling 2>/dev/null || true
  fi
}

# ---------- Internal state ----------

# Last-active teammate handle — updated on each relay cycle.
_PMB_LAST_ACTIVE_HANDLE=""

# ---------- Public API ----------

# planning_spawn_subagent PERSONA [SKILL_SLUG]
# Spawn a planning authoring subagent via spawn_teammate.
# Returns the handle on stdout.
planning_spawn_subagent() {
  local persona="${1:-}"
  local skill_slug="${2:-}"

  _pmb_ensure_dt

  if [ -z "$persona" ]; then
    printf 'planning-mode-b-bridge: persona is required\n' >&2
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
  handle="$(spawn_teammate "$persona" --context "planning:${skill_slug:-unknown}")"
  local rc=$?
  if [ "$errexit_was_set" -eq 1 ]; then set -e; fi

  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq "${_DT_CEILING_EXIT_CODE:-8}" ]; then
      # Capacity, not failure: the ceiling was saturated after the bounded
      # retry. Report it and hand the documented code back so the caller can
      # queue and retry, rather than dying at the assignment under errexit.
      printf 'planning-mode-b-bridge: teammate ceiling saturated, queued for retry\n' \
        >&2
    fi
    return "$rc"
  fi

  _PMB_LAST_ACTIVE_HANDLE="$handle"

  printf '%s\n' "$handle"
}

# planning_relay_turn HANDLE PAYLOAD
# Relay an authoring turn back to the team lead. Updates last-active
# tracking, then delegates verbatim relay to dispatch-teammate.
planning_relay_turn() {
  local handle="${1:-}"
  local payload="${2:-}"

  _pmb_ensure_dt

  # Update last-active before relay.
  _PMB_LAST_ACTIVE_HANDLE="$handle"

  relay_to_team_lead "$handle" "$payload"
}

# planning_shutdown
# Shut every active planning teammate down at skill exit. Delegates to
# shutdown_all so no teammate pane is left orphaned.
planning_shutdown() {
  _pmb_ensure_dt
  shutdown_all
}

# ---------- Source guard — mark loaded ----------
_PMB_LOADED=1
