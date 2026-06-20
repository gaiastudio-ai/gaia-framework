#!/usr/bin/env bash
# execution-mode-b-bridge.sh — Mode B execution/sprint-lifecycle bridge library.
# Sourceable, NOT executable.
#
# Bridges the execution/sprint skills (dev-story, sprint-plan, run-all-reviews,
# add-feature, quick-spec, quick-dev, readiness-check, atdd, sprint-review) to
# the shared Mode B dispatch-teammate library. Execution-specific concerns:
#   - Spawn the working subagent (stack developer / sm / etc.) as a persistent
#     teammate that survives across procedural phases (e.g. dev-story carries a
#     single stack developer through plan, implement, test, and PR phases
#     without re-spawning).
#   - Relay each phase turn back to the team lead (transcript parity with the
#     Mode A subagent-dispatch path).
#   - Shut every teammate down at skill exit (no leaked panes).
#
# CLEAN-ROOM INVARIANT: reviewer personas MUST NOT be spawned as persistent
# teammates. run-all-reviews keeps its six reviewers as one-shot subagents that
# judge from a clean context. The clean-room gate inside the shared library
# blocks any reviewer persona before a teammate is created, so even an errant
# spawn attempt from this bridge fails closed.
#
# The library degrades to Mode A foreground fallback when the substrate is
# absent (dispatch-teammate handles the fallback + MODE_B_FALLBACK token
# emission). The artifact structure is identical between modes: only the
# dispatch seam changes, never the produced output shape.

# ---------- Source guard ----------

if [ "${_EMB_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Dependency: dispatch-teammate.sh ----------

_EMB_DT_LIB=""

_emb_ensure_dt() {
  if [ -z "$_EMB_DT_LIB" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _EMB_DT_LIB="$lib_dir/dispatch-teammate.sh"
  fi
  if [ "${_DT_LOADED:-0}" != "1" ]; then
    # shellcheck source=/dev/null
    . "$_EMB_DT_LIB"
  fi
}

# ---------- Internal state ----------

# Last-active teammate handle — updated on each relay cycle.
_EMB_LAST_ACTIVE_HANDLE=""

# ---------- Public API ----------

# execution_spawn_subagent PERSONA [SKILL_SLUG]
# Spawn an execution working subagent via spawn_teammate as a persistent
# teammate. The same handle is reused across procedural phases (plan /
# implement / test / PR) — callers drive each phase with drive_turn against
# the returned handle rather than re-spawning. Returns the handle on stdout.
# The clean-room gate inside the shared library refuses reviewer personas.
execution_spawn_subagent() {
  local persona="${1:-}"
  local skill_slug="${2:-}"

  _emb_ensure_dt

  if [ -z "$persona" ]; then
    printf 'execution-mode-b-bridge: persona is required\n' >&2
    return 1
  fi

  local handle
  handle="$(spawn_teammate "$persona" --context "execution:${skill_slug:-unknown}")"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  _EMB_LAST_ACTIVE_HANDLE="$handle"

  printf '%s\n' "$handle"
}

# execution_relay_turn HANDLE PAYLOAD
# Relay a phase turn back to the team lead. Updates last-active tracking, then
# delegates verbatim relay to dispatch-teammate so the transcript (and hence
# the produced artifact) is identical to Mode A.
execution_relay_turn() {
  local handle="${1:-}"
  local payload="${2:-}"

  _emb_ensure_dt

  # Update last-active before relay.
  _EMB_LAST_ACTIVE_HANDLE="$handle"

  relay_to_team_lead "$handle" "$payload"
}

# execution_shutdown
# Shut every active execution teammate down at skill exit. Delegates to
# shutdown_all so no teammate pane is left orphaned. Wire this via
# `trap execution_shutdown EXIT` in the skill body.
execution_shutdown() {
  _emb_ensure_dt
  shutdown_all
}

# ---------- Source guard — mark loaded ----------
_EMB_LOADED=1
