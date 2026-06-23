#!/usr/bin/env bash
# research-mode-b-bridge.sh — Mode B research / testing / infra bridge library.
# Sourceable, NOT executable.
#
# Bridges the research-, testing-, and infrastructure-class skills (nfr,
# advanced-elicitation, market-research, tech-research, domain-research,
# innovation, infra-design, deploy, init, brownfield, mobile-testing,
# perf-testing, test-a11y, test-perf, a11y-testing, storytelling) to the
# shared Mode B dispatch-teammate library. Bridge concerns:
#   - Run the working subagent (analyst / devops / performance / qa /
#     test-architect / innovation-strategist / storyteller / architect) as a
#     persistent teammate.
#   - Relay each working turn back to the team lead so the transcript matches
#     the Mode A subagent path byte-for-byte.
#   - Shut every teammate down at skill exit so no pane is left orphaned.
#
# The library degrades to a Mode A foreground fallback when the substrate is
# absent; dispatch-teammate owns that fallback and the MODE_B_FALLBACK token.
# The produced artifact shape is identical between modes: only the dispatch
# seam changes, never the output.
#
# ROUND-TRIP CONTRACT. This bridge does bookkeeping ONLY. The actual per-turn
# teammate round-trip — the orchestrator emitting a real SendMessage with the
# mandatory reply-routing reminder, the teammate replying via
# SendMessage(to: team-lead), and the relay back to the transcript — is driven
# by the skill orchestrator, not by these functions (bash cannot emit
# SendMessage). Callers MUST drive each working turn per the canonical contract
# at knowledge/mode-b-round-trip-contract.md. research_spawn_subagent /
# research_relay_turn / research_shutdown are the bookkeeping seams that
# contract references.

# ---------- Source guard ----------

if [ "${_RMB_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Dependency: dispatch-teammate.sh ----------

_RMB_DT_LIB=""

_rmb_ensure_dt() {
  if [ -z "$_RMB_DT_LIB" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _RMB_DT_LIB="$lib_dir/dispatch-teammate.sh"
  fi
  if [ "${_DT_LOADED:-0}" != "1" ]; then
    # shellcheck source=/dev/null
    . "$_RMB_DT_LIB"
  fi
}

# ---------- Internal state ----------

# Last-active teammate handle — updated on each relay cycle.
_RMB_LAST_ACTIVE_HANDLE=""

# ---------- Public API ----------

# research_spawn_subagent PERSONA [SKILL_SLUG]
# Run a working subagent as a persistent teammate via spawn_teammate.
# Returns the handle on stdout.
research_spawn_subagent() {
  local persona="${1:-}"
  local skill_slug="${2:-}"

  _rmb_ensure_dt

  if [ -z "$persona" ]; then
    printf 'research-mode-b-bridge: persona is required\n' >&2
    return 1
  fi

  local handle
  handle="$(spawn_teammate "$persona" --context "research:${skill_slug:-unknown}")"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  _RMB_LAST_ACTIVE_HANDLE="$handle"

  printf '%s\n' "$handle"
}

# research_relay_turn HANDLE PAYLOAD
# Relay a working turn back to the team lead. Updates last-active tracking,
# then routes the verbatim relay through dispatch-teammate.
research_relay_turn() {
  local handle="${1:-}"
  local payload="${2:-}"

  _rmb_ensure_dt

  # Update last-active before relay.
  _RMB_LAST_ACTIVE_HANDLE="$handle"

  relay_to_team_lead "$handle" "$payload"
}

# research_shutdown
# Shut every active teammate down at skill exit. Routes through shutdown_all
# so no teammate pane is left orphaned.
research_shutdown() {
  _rmb_ensure_dt
  shutdown_all
}

# ---------- Source guard — mark loaded ----------
_RMB_LOADED=1
