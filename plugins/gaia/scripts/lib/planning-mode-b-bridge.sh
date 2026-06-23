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

  local handle
  handle="$(spawn_teammate "$persona" --context "planning:${skill_slug:-unknown}")"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
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
