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
# dispatch seam changes, never the produced output shape. When a spawn is given
# a story key, that degradation also arrives programmatically — the fallback
# exit code, which this bridge propagates to its caller, plus a reason the
# caller can read back through execution_fallback_reason.
#
# ROUND-TRIP CONTRACT. This bridge does bookkeeping ONLY. The actual per-turn
# teammate round-trip — the orchestrator emitting a real SendMessage with the
# mandatory reply-routing reminder, the teammate replying via
# SendMessage(to: team-lead), and the relay back to the transcript — is driven
# by the skill orchestrator, not by these functions (bash cannot emit
# SendMessage). Callers MUST drive each phase turn per the canonical contract
# at knowledge/mode-b-round-trip-contract.md. execution_spawn_subagent /
# execution_relay_turn / execution_shutdown are the bookkeeping seams that
# contract references.

# ---------- Source guard ----------

if [ "${_EMB_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Dependency: dispatch-teammate.sh ----------

_EMB_DT_LIB=""
_EMB_LOCK_LIB=""

_emb_ensure_dt() {
  if [ -z "$_EMB_DT_LIB" ] || [ -z "$_EMB_LOCK_LIB" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _EMB_DT_LIB="$lib_dir/dispatch-teammate.sh"
    _EMB_LOCK_LIB="$lib_dir/acquire-lock.sh"
  fi
  if [ "${_DT_LOADED:-0}" != "1" ]; then
    # shellcheck source=/dev/null
    . "$_EMB_DT_LIB"
  fi
  # The lock helper backs the per-handle attribution counter.
  if ! declare -F acquire_lock >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$_EMB_LOCK_LIB"
  fi
}

# ---------- Internal state ----------

# Relay attribution lives on disk, one file per handle, under
#   $GAIA_SESSION_DIR/relay-attribution/<handle>
# alongside the dispatch library's own registry/ and turns/ directories.
#
# One file per handle is what makes concurrent relays safe by construction:
# two teammates relaying at once write two different paths and cannot
# interleave. It also replaces the single session-wide last-active handle this
# bridge used to keep — one scalar cannot describe which of several concurrent
# teammates a message came from, and nothing ever read it.
#
# The reason for the most recent programmatic fallback is kept beside it at
#   $GAIA_SESSION_DIR/mode-b-fallback-reason
# rather than in a shell variable, so a caller that spawned in a subshell can
# still ask why the dispatch fell back.

_emb_attribution_dir() {
  local dir="${GAIA_SESSION_DIR:?GAIA_SESSION_DIR must be set}/relay-attribution"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

_emb_fallback_reason_file() {
  printf '%s' "${GAIA_SESSION_DIR:?GAIA_SESSION_DIR must be set}/mode-b-fallback-reason"
}

# ---------- Public API ----------

# execution_spawn_subagent PERSONA [SKILL_SLUG] [STORY_KEY]
# Spawn an execution working subagent via spawn_teammate as a persistent
# teammate. The same handle is reused across procedural phases (plan /
# implement / test / PR) — callers drive each phase with drive_turn against
# the returned handle rather than re-spawning. Returns the handle on stdout.
# The clean-room gate inside the shared library refuses reviewer personas.
#
# Passing STORY_KEY opts into the parallel-aware contract: the handle is keyed
# by story rather than by process id, so several same-persona teammates can run
# at once, and an unavailable substrate returns the fallback exit code with no
# handle instead of degrading silently. Called with two arguments the seam
# behaves exactly as before.
execution_spawn_subagent() {
  local persona="${1:-}"
  local skill_slug="${2:-}"
  local story_key="${3:-}"

  # Sample the caller's errexit BEFORE loading dependencies: the libraries this
  # bridge sources set their own shell options at source time, so reading the
  # flag afterwards would report theirs rather than the caller's.
  #
  # Note for callers: sourcing this bridge turns errexit ON in your shell, and a
  # story-keyed spawn returns the fallback code as a NORMAL outcome. So capture
  # the output in a guarded form — assign, then read the status:
  #     handle="$(execution_spawn_subagent "$p" "$s" "$key")" || rc=$?
  # A bare unguarded assignment is killed at the assignment itself. Assigning
  # inside `if ! handle="$(...)"` does not work either: $? is already reset by
  # the time the branch runs, so the separate-assignment form is the only way to
  # branch on the specific code.
  local errexit_was_set=0
  case "$-" in *e*) errexit_was_set=1 ;; esac

  _emb_ensure_dt

  if [ -z "$persona" ]; then
    printf 'execution-mode-b-bridge: persona is required\n' >&2
    return 1
  fi

  # Two rules govern this capture, and both are load-bearing:
  #   - declaration and assignment stay separate, because `local h="$(...)"`
  #     would make the next $? the status of `local` itself, not the spawn's;
  #   - `set -e` is lifted across the assignment, because a failing command
  #     substitution otherwise terminates this function at the assignment and
  #     the status is never inspected at all. The story-keyed spawn returns a
  #     non-zero code as a normal outcome, so it must be caught, not fatal.
  # This is a sourced library, so shell options are the CALLER's: the lift must
  # be restored to whatever the caller had, never switched on unconditionally.
  # A caller that deliberately ran with `set +e` to inspect the fallback code
  # would otherwise find errexit switched on underneath it.
  local handle
  set +e
  if [ -n "$story_key" ]; then
    handle="$(spawn_teammate "$persona" \
      --context "execution:${skill_slug:-unknown}" --story-key "$story_key")"
  else
    handle="$(spawn_teammate "$persona" --context "execution:${skill_slug:-unknown}")"
  fi
  local rc=$?
  if [ "$errexit_was_set" -eq 1 ]; then set -e; fi
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq "${_DT_FALLBACK_EXIT_CODE:-7}" ]; then
      # Parse the machine-readable record rather than leaving it unread, and
      # store the reason so the caller can report the degradation honestly.
      _emb_store_fallback_reason "$handle"
    fi
    return "$rc"
  fi

  # Seed attribution at spawn time so a story-keyed handle is attributable
  # even before its first relay.
  if [ -n "$story_key" ]; then
    _emb_write_attribution "$handle" "$story_key" "$persona" 0
  fi

  printf '%s\n' "$handle"
}

# _emb_store_fallback_reason RECORD — extract reason: from the fallback record
# and persist it for execution_fallback_reason.
_emb_store_fallback_reason() {
  local record="$1" reason
  reason="$(printf '%s\n' "$record" | sed -n 's/.*reason:\([^ ]*\).*/\1/p' | head -1)"
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason" > "$(_emb_fallback_reason_file)"
  fi
}

# execution_fallback_reason
# Print why the most recent story-keyed dispatch fell back to foreground work.
# This is the reader that keeps the machine-readable fallback record from being
# write-only: the code tells a caller to degrade, this tells it what to say.
execution_fallback_reason() {
  _emb_ensure_dt
  local file
  file="$(_emb_fallback_reason_file)"
  if [ ! -f "$file" ]; then
    return 1
  fi
  cat "$file"
}

# execution_attribution_for HANDLE
# Print the story key a handle's relays are attributed to, or nothing when the
# handle carries no story. The reader that proves attribution is consumed and
# not merely recorded.
execution_attribution_for() {
  _emb_ensure_dt
  local handle="${1:-}"
  local file
  file="$(_emb_attribution_dir)/$handle"
  if [ ! -f "$file" ]; then
    return 0
  fi
  sed -n 's/^story_key://p' "$file" | head -1
}

# _emb_write_attribution HANDLE STORY_KEY PERSONA RELAYS — write the record
# via a temporary file and mv, so a concurrent reader never sees it partial.
_emb_write_attribution() {
  local handle="$1" story_key="$2" persona="$3" relays="$4"
  local dir file tmp
  dir="$(_emb_attribution_dir)"
  file="$dir/$handle"
  tmp="$file.$$.tmp"
  printf 'story_key:%s\npersona:%s\nrelays:%s\nlast_relay:%s\n' \
    "$story_key" "$persona" "$relays" "$(_dt_iso8601)" > "$tmp"
  mv -f "$tmp" "$file"
}

# _emb_bump_attribution HANDLE — read-modify-write the relay counter under the
# per-handle lock. Runs inside a subshell so the EXIT trap that releases the
# lock, and the file descriptor it uses, cannot leak into the sourced caller.
_emb_bump_attribution() {
  local handle="$1"
  local dir file
  dir="$(_emb_attribution_dir)"
  file="$dir/$handle"

  # The lock is per handle, so two different teammates never contend; it exists
  # for the same-handle case, where concurrent relays would otherwise lose an
  # update. A failure here must never cost the caller its relay, so the
  # subshell's status is captured rather than left to abort the function under
  # `set -e`.
  local errexit_was_set=0
  case "$-" in *e*) errexit_was_set=1 ;; esac
  set +e
  (
    if ! acquire_lock "$file.lock" 5 9; then
      exit 1
    fi
    trap 'release_lock 9 2>/dev/null || true' EXIT
    local story_key persona relays
    story_key="$(sed -n 's/^story_key://p' "$file" 2>/dev/null | head -1)"
    persona="$(sed -n 's/^persona://p' "$file" 2>/dev/null | head -1)"
    relays="$(sed -n 's/^relays://p' "$file" 2>/dev/null | head -1)"
    [ -n "$relays" ] || relays=0
    _emb_write_attribution "$handle" "$story_key" "$persona" "$((relays + 1))"
  )
  local rc=$?
  if [ "$errexit_was_set" -eq 1 ]; then set -e; fi
  return "$rc"
}

# execution_relay_turn HANDLE PAYLOAD
# Relay a phase turn back to the team lead: delegate the verbatim relay to
# dispatch-teammate so the transcript (and hence the produced artifact) is
# identical to Mode A, then record which story the relay belongs to.
#
# Ordering is deliberate. The relay runs FIRST and OUTSIDE the lock, so a
# delivered reply always reaches the transcript even when the bookkeeping
# behind it cannot proceed. Attribution is observability; losing it warns,
# it never costs a reply and never changes the relay's exit status.
execution_relay_turn() {
  local handle="${1:-}"
  local payload="${2:-}"

  _emb_ensure_dt

  # A handle with no registry entry belongs to a teammate that was never
  # spawned — the shape left behind when a dispatch fell back. Relaying
  # against it would append an unattributed entry and report success, so
  # refuse with the fallback code instead, writing nothing anywhere.
  #
  # The guard lives here rather than in the shared relay_to_team_lead, whose
  # permissive behaviour several other cohort bridges depend on.
  if [ -n "$handle" ] && [ ! -f "${GAIA_SESSION_DIR:?}/registry/$handle" ]; then
    printf 'execution-mode-b-bridge: no active teammate for %s — refusing to relay\n' \
      "$handle" >&2
    return "${_DT_FALLBACK_EXIT_CODE:-7}"
  fi

  local relay_rc=0
  relay_to_team_lead "$handle" "$payload" || relay_rc=$?

  # Attribution describes a relay that happened. If the shared library refused
  # the relay, there is nothing to attribute, and running the bookkeeping anyway
  # would leave state behind for a message that was never delivered.
  if [ "$relay_rc" -eq 0 ]; then
    if ! _emb_bump_attribution "$handle"; then
      printf 'execution-mode-b-bridge: attribution unavailable for %s (continuing)\n' \
        "$handle" >&2
    fi
  fi

  return "$relay_rc"
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
