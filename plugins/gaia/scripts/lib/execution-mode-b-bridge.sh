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

# _emb_ensure_dt — load the bridge's dependencies on first use.
#
# Both libraries run `set -euo pipefail` at source time, and because this is a
# LAZY load that happens inside whichever seam the caller reached first, those
# options would land in the CALLER's shell — turning errexit on underneath a
# caller that deliberately ran `set +e` to branch on the fallback exit code,
# and doing so at an unpredictable moment (the first seam call, not the source).
# Sampling and restoring the caller's flags HERE fixes every seam at once,
# rather than leaving each new call site to remember the dance.
_emb_ensure_dt() {
  if [ -z "$_EMB_DT_LIB" ] || [ -z "$_EMB_LOCK_LIB" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _EMB_DT_LIB="$lib_dir/dispatch-teammate.sh"
    _EMB_LOCK_LIB="$lib_dir/acquire-lock.sh"
  fi

  local errexit_was_set=0
  case "$-" in *e*) errexit_was_set=1 ;; esac

  if [ "${_DT_LOADED:-0}" != "1" ]; then
    # shellcheck source=/dev/null
    . "$_EMB_DT_LIB"
  fi
  # The lock helper backs the per-handle attribution counter.
  if ! declare -F acquire_lock >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$_EMB_LOCK_LIB"
  fi

  # Restore the caller's errexit. Only ever turns it back OFF for a caller that
  # had it off; a caller that had it on keeps it on.
  if [ "$errexit_was_set" -eq 0 ]; then
    set +e
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
# The reason for a programmatic degradation is kept beside the attribution map,
# one file per story key, under
#   $GAIA_SESSION_DIR/mode-b-fallback-reason/<story-key>
# rather than in a shell variable, so a caller that spawned in a subshell can
# still ask why its dispatch fell back.
#
# One file per key, for the same reason attribution is per handle: this library
# exists to let several stories dispatch at once, and a single session-global
# scalar cannot say WHICH of three concurrent fallbacks it describes — the last
# writer would simply win and the other two stories would read a reason that
# belongs to a different story. Each record carries its own story key and the
# reason, is written atomically (temp + mv) so a concurrent reader never sees a
# partial line, and is cleared when a keyed spawn for that story later succeeds
# — otherwise a stale reason outlives the condition it described.

_emb_attribution_dir() {
  local dir="${GAIA_SESSION_DIR:?GAIA_SESSION_DIR must be set}/relay-attribution"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

_emb_fallback_reason_dir() {
  local dir="${GAIA_SESSION_DIR:?GAIA_SESSION_DIR must be set}/mode-b-fallback-reason"
  # This path held a single FILE before the store became per story. A session
  # carried over from that layout would fail every mkdir here and silently lose
  # its reasons, so retire the stale file rather than fail around it. Its lone
  # value described one already-finished dispatch and has no per-story identity
  # to migrate — there is nothing in it worth keeping.
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    rm -f "$dir"
  fi
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# _emb_reason_slug VALUE — reduce a story key or handle to one path component.
# The dispatch boundary already refuses a key that is not [A-Za-z0-9._-], so
# this is a defence-in-depth guard for a value arriving from anywhere else: it
# guarantees the reason store cannot be steered outside its own directory.
_emb_reason_slug() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-'
}

# _emb_write_reason STORY_KEY REASON — record why a dispatch for STORY_KEY
# degraded. Atomic (temp + mv), so a concurrent reader sees the whole record or
# the previous one, never a half-written line.
_emb_write_reason() {
  local story_key="$1" reason="$2"
  [ -n "$story_key" ] || return 0
  local dir file tmp
  dir="$(_emb_fallback_reason_dir)"
  file="$dir/$(_emb_reason_slug "$story_key")"
  tmp="$file.$$.tmp"
  printf 'story_key:%s\nreason:%s\nrecorded:%s\n' \
    "$story_key" "$reason" "$(_dt_iso8601)" > "$tmp"
  mv -f "$tmp" "$file"
}

# _emb_clear_reason STORY_KEY — drop a recorded reason once a dispatch for that
# story has succeeded, so a later reader is never told a live story degraded.
_emb_clear_reason() {
  local story_key="$1"
  [ -n "$story_key" ] || return 0
  rm -f "$(_emb_fallback_reason_dir)/$(_emb_reason_slug "$story_key")"
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
    # This story is now running, so any reason recorded for an earlier degraded
    # attempt no longer describes it. Leaving it would have a later reader
    # report a live story as fallen back.
    _emb_clear_reason "$story_key"
  fi

  printf '%s\n' "$handle"
}

# _emb_store_fallback_reason RECORD — extract reason: from the fallback record
# and persist it for execution_fallback_reason.
# The record's shape is fixed by _dt_emit_fallback_record:
#   mode_b_fallback story_key:<key> persona:<persona> reason:<reason>
# so `reason:` is the LAST space-delimited field, and that is the field this
# reader takes — by anchoring to the end of the record, not by relying on a
# greedy `.*` happening to run past an earlier look-alike token. The key is
# validated at the dispatch boundary and can no longer carry a space or a
# colon, so no second `reason:` token can appear; anchoring means this reader
# stays correct even so, and stays correct if the record ever gains a field.
_emb_store_fallback_reason() {
  local record="$1" reason story_key
  # ^…$ anchors the whole line; [^ ]*$ pins the captured value to the final
  # field, so only a trailing `reason:` can match.
  reason="$(printf '%s\n' "$record" | sed -n 's/^.* reason:\([^ ]*\)$/\1/p' | head -1)"
  # The record carries the story key too; keeping it is what lets a caller ask
  # about ITS story rather than about whichever dispatch degraded most recently.
  story_key="$(printf '%s\n' "$record" | sed -n 's/^mode_b_fallback story_key:\([^ ]*\).*$/\1/p' | head -1)"
  if [ -n "$reason" ] && [ -n "$story_key" ]; then
    _emb_write_reason "$story_key" "$reason"
  fi
}

# execution_fallback_reason [STORY_KEY]
# Print why a story-keyed dispatch degraded to foreground work. This is the
# reader that keeps the machine-readable fallback record from being write-only:
# the exit code tells a caller to degrade, this tells it what to say.
#
# Precedence is explicit:
#   - WITH a story key — report that story's reason, or status 1 if it has
#     none. This is the form a parallel caller wants: it answers about the
#     story the caller is running, regardless of what other stories did.
#   - WITHOUT one — report the most recently recorded reason across the
#     session. Retained for a single-story caller that never had a key to hand;
#     under concurrency it is inherently ambiguous, so prefer the keyed form.
execution_fallback_reason() {
  _emb_ensure_dt
  local story_key="${1:-}"
  local dir file
  dir="$(_emb_fallback_reason_dir)"

  if [ -n "$story_key" ]; then
    file="$dir/$(_emb_reason_slug "$story_key")"
    if [ ! -f "$file" ]; then
      return 1
    fi
  else
    # Most recent by the `recorded:` stamp inside each record rather than by
    # filesystem mtime: the stamp is what the writer actually asserts, and
    # sorting record contents avoids parsing `ls` output entirely. Reason slugs
    # cannot contain whitespace or newlines (see _emb_reason_slug), so the
    # stamp-then-path line format is unambiguous.
    local newest
    newest="$(
      find "$dir" -type f -maxdepth 1 2>/dev/null | while IFS= read -r candidate; do
        printf '%s %s\n' \
          "$(sed -n '/^recorded:/{s/^recorded://p;q;}' "$candidate" 2>/dev/null)" \
          "$candidate"
      done | sort | tail -1
    )"
    file="${newest#* }"
    [ -n "$file" ] && [ -f "$file" ] || return 1
  fi

  sed -n '/^reason:/{s/^reason://p;q;}' "$file"
}

# execution_attribution_for HANDLE
# Print the story key a handle's relays are attributed to, or nothing when the
# handle carries no story. The reader that proves attribution is consumed and
# not merely recorded.
# The record is written by _emb_write_attribution with `story_key:` as its
# FIRST line, so the first match is the authoritative one and `1q` stops the
# reader there deliberately rather than leaving a later look-alike line to be
# discarded by luck. `^story_key:` is anchored to the start of the line, so a
# value that merely contains the token (`relays:0 story_key:x`) is not a match.
# Keys are validated at the dispatch boundary and can no longer span lines, so
# a second `story_key:` line cannot be injected; the anchoring keeps this
# reader deterministic regardless.
execution_attribution_for() {
  _emb_ensure_dt
  local handle="${1:-}"

  # Match the guard on the write path (execution_relay_turn): a handle is a
  # single path component, never a traversal. The reader is only ever given a
  # sanitiser-derived handle today, but a reader that silently accepts `..`
  # would hand a future caller an arbitrary-file read.
  case "$handle" in
    ''|*/*|*..*)
      printf 'execution-mode-b-bridge: invalid handle %s — refusing to read attribution\n' \
        "$handle" >&2
      return 1
      ;;
  esac

  local file
  file="$(_emb_attribution_dir)/$handle"
  if [ ! -f "$file" ]; then
    return 0
  fi
  # `s/…/p;q` on a matching line prints and quits, so the FIRST `story_key:`
  # line wins by construction — chosen on purpose, since that is the line
  # _emb_write_attribution authors. Quitting on the first match (rather than on
  # line 1) keeps the reader correct if the record's field order ever changes.
  sed -n '/^story_key:/{s/^story_key://p;q;}' "$file"
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
    # Timeout is overridable because it is a throughput/accuracy trade-off, not
    # a constant: under many concurrent relays on ONE handle, a contended waiter
    # that times out drops its attribution increment (the relay itself still
    # lands — attribution is observability and never costs a reply). A caller
    # driving an unusually hot handle can raise this rather than lose counts.
    if ! acquire_lock "$file.lock" "${GAIA_MODE_B_ATTRIBUTION_LOCK_TIMEOUT:-5}" 9; then
      exit 1
    fi
    trap 'release_lock 9 2>/dev/null || true' EXIT
    local story_key persona relays
    # Identity comes from the REGISTRY, which is where a spawn actually records
    # it, not from the attribution file being rewritten. Reading identity out of
    # that file only works when something seeded it first — true for a spawn
    # through this bridge's own seam, but NOT for a handle spawned directly via
    # the shared library and then relayed here, which would rewrite a record it
    # had never written and produce empty story_key:/persona: fields. Seeding
    # from the registry on every bump makes the record correct whichever way the
    # handle was created, and refreshes it if the registry entry changed.
    story_key="$(_dt_read_story_key "$handle")"
    persona="$(_dt_read_persona "$handle")"
    # The relay counter is the one field that genuinely accumulates here, so it
    # is the only one carried forward from the previous record.
    relays="$(sed -n '/^relays:/{s/^relays://p;q;}' "$file" 2>/dev/null)"
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
    # This path and a spawn-time substrate fallback both return the same code,
    # so the code alone cannot tell a caller which happened — and they call for
    # different responses ("degrade to sequential work" vs "a relay was
    # dropped"). Record a distinct reason, keyed by the handle, so the two are
    # separable by a caller that asks. Without this the reader would answer a
    # relay refusal with a stale `substrate-unavailable` from an earlier spawn.
    _emb_write_reason "$handle" "unregistered-handle"
    return "${_DT_FALLBACK_EXIT_CODE:-7}"
  fi

  local relay_rc=0
  relay_to_team_lead "$handle" "$payload" || relay_rc=$?

  # Attribution describes a relay that happened. If the shared library refused
  # the relay, there is nothing to attribute, and running the bookkeeping anyway
  # would leave state behind for a message that was never delivered.
  #
  # It is also skipped for a KEYLESS handle. Attribution exists to say which
  # STORY a relay belongs to, and a keyless teammate has no story — the record
  # written for one carries an empty story_key: and answers nothing. Doing it
  # anyway would charge every long-standing keyless caller a lock acquire and
  # a read-modify-write per turn for a record no reader can use. Keyed relays
  # are unaffected; only the callers that opted into stories pay for them.
  if [ "$relay_rc" -eq 0 ] && [ -n "$(_dt_read_story_key "$handle")" ]; then
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
