#!/usr/bin/env bash
# dispatch-teammate.sh — shared Mode B dispatch library.
# Sourceable, NOT executable.
#
# Exposes 6 public functions for persistent-teammate dispatch:
#   spawn_teammate      — spawn a named teammate agent
#   drive_turn          — send a prompt to a teammate
#   await_reply         — wait for a teammate's reply
#   relay_to_team_lead  — forward teammate output to the team lead
#   shutdown_teammate   — shut down a single teammate
#   shutdown_all        — shut down every active teammate
#
# Session state is tracked via flat files under GAIA_SESSION_DIR:
#   registry/           — one file per active teammate (handle as filename)
#   provenance.log      — append-only dispatch provenance log
#   transcript.md       — append-only session transcript
#
# Substrate detection:
#   The live runtime primitives (Agent with run_in_background + SendMessage)
#   may not be available in all Claude Code contexts. When unavailable, the
#   library degrades to Mode A foreground fallback and emits a single
#   machine-parseable warning token MODE_B_FALLBACK to stderr.
#
#   A caller that passes --story-key additionally receives a programmatic
#   signal, so it can branch on a return value instead of parsing stderr:
#   exit 7 and, on stdout, one machine-readable record in place of the handle
#     mode_b_fallback story_key:<key> persona:<persona> reason:<reason>
#   The exit code is the control-flow contract — treat it as an instruction to
#   degrade to sequential work with phase order preserved, never as a refusal.
#   Keyless callers are unaffected: they still receive a handle and exit 0.
#
# Story-keyed handles:
#   spawn_teammate --story-key builds the handle from the persona and the key
#   rather than the process id. Because the process id is constant within one
#   session, a process-derived handle collides whenever the same persona is
#   dispatched twice; keying by story removes that collision, makes a retry
#   land on the same handle, and lets each relayed message be attributed to
#   the story it belongs to.
#
# The 8-teammate ceiling is enforced at the registry level.

# ---------- Source guard ----------

if [ "${_DT_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

# ---------- Internal state ----------

# Maximum concurrent teammates.
_DT_MAX_TEAMMATES=8

# Exit code returned to a story-keyed caller when the substrate is absent.
# Story-keyed callers opt into the programmatic fallback contract, so they get
# a distinct code they can branch on instead of parsing stderr. The code is
# named once here; every return site references the constant so the documented
# value and the returned value cannot drift apart.
_DT_FALLBACK_EXIT_CODE=7

# Registry directory — one file per active teammate.
# Initialised lazily on first spawn, not at source time.
_DT_REGISTRY_DIR=""

# Path to reviewer-personas.txt — resolved relative to this library.
_DT_REVIEWER_PERSONAS=""

# ---------- Internal helpers ----------

# _dt_die MSG — emit error and return 1 from sourced context.
_dt_die() {
  printf 'dispatch-teammate: %s\n' "$1" >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
}

# _dt_ensure_registry — create the registry dir if needed.
_dt_ensure_registry() {
  if [ -z "$_DT_REGISTRY_DIR" ]; then
    _DT_REGISTRY_DIR="${GAIA_SESSION_DIR:?GAIA_SESSION_DIR must be set}/registry"
  fi
  mkdir -p "$_DT_REGISTRY_DIR"
}

# _dt_active_count — print the number of active teammates.
_dt_active_count() {
  _dt_ensure_registry
  find "$_DT_REGISTRY_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '
}

# _dt_iso8601 — print current time in ISO-8601.
_dt_iso8601() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Maximum length of a sanitised story key inside a handle. Bounds the handle so
# a pathological key cannot produce a name the registry directory cannot hold.
_DT_STORY_KEY_MAX=64

# _dt_validate_story_key KEY — accept or refuse a RAW story key at the trust
# boundary, BEFORE it reaches any persistent sink.
#
# Why a boundary check rather than per-sink escaping. The sanitiser below
# protects the HANDLE (a filename) and nothing else: the raw key is what gets
# stored in the registry and rendered into the transcript metadata comment, and
# both of those are structured, single-line-delimited formats. A key carrying a
# newline therefore appends forged `field:value` records to the registry (a
# forged `persona:` line is read straight back by _dt_read_persona), and a key
# carrying `-->` closes the metadata comment early and lands caller-controlled
# markup in the append-only transcript body, where nothing can retract it.
# Escaping at each sink would mean keeping several escapers in step forever and
# would silently mangle the stored key; refusing the input once, here, keeps a
# single rule and stores exactly what the caller passed.
#
# The accepted class is deliberately conservative — ASCII letters, digits, dot,
# underscore and hyphen, 1 to 64 characters:
#
#   - it admits every story-key shape the framework issues or has planned
#     (epic/story keys, dotted and underscored variants, slugs);
#   - it excludes, by construction and not by enumeration, every character that
#     could punctuate a record or a comment: whitespace and control characters
#     (so no key can span lines), `:` (the registry/record field separator),
#     `<` and `>` (so neither `-->` nor `<!--` can be formed), `/` and the
#     path-ish forms built from it;
#   - the 64-character cap matches the sanitised-token bound, so a key that
#     passes here can never outgrow the handle it produces.
#
# Refusal is fail-closed: status 1 with a diagnostic, and the caller returns
# before anything is written to the registry, the transcript, the fallback
# record or the attribution store.
_dt_validate_story_key() {
  local raw="$1"

  if [ -z "$raw" ]; then
    _dt_die "spawn_teammate: --story-key requires a non-empty key"
    return 1
  fi

  # The bracket expression lists its characters explicitly rather than using a
  # named class such as [:alnum:], so it is byte-wise and locale-independent:
  # this is a SOURCED library and must not depend on — or mutate — the calling
  # shell's locale to decide what it accepts.
  case "$raw" in
    *[!A-Za-z0-9._-]*)
      _dt_die "spawn_teammate: story key '$raw' contains characters outside [A-Za-z0-9._-] — refusing"
      return 1
      ;;
  esac

  if [ "${#raw}" -gt "$_DT_STORY_KEY_MAX" ]; then
    _dt_die "spawn_teammate: story key '$raw' exceeds $_DT_STORY_KEY_MAX characters — refusing"
    return 1
  fi

  return 0
}

# _dt_sanitize_story_key KEY — reduce a story key to a handle-safe token.
#
# Reuses the persona slug transform (every character outside [:alnum:] becomes
# a dash), then collapses dash runs and trims the ends, so a key written with
# dots, underscores or mixed separators yields one clean token. Truncation is
# applied last, so the result is always a valid single filename component.
# The transform is deliberately lossy: two differently-written keys can reduce
# to the same token. Uniqueness is therefore enforced on the RAW key stored in
# the registry, not on this token — see spawn_teammate's identity check.
#
# LC_ALL=C is pinned on the `tr` invocations themselves, not exported. `[:alnum:]`
# resolves against the ambient locale, so without this the SAME key sanitises to
# two different tokens — and therefore two different handles, registry files and
# attribution records — depending on the caller's locale. Scoping the setting to
# these commands keeps the transform byte-wise without a sourced library reaching
# out and changing the calling shell's locale.
_dt_sanitize_story_key() {
  local raw="$1" token
  token="$(printf '%s' "$raw" | LC_ALL=C tr -c '[:alnum:]' '-' | LC_ALL=C tr -s '-')"
  token="${token#-}"
  token="${token%-}"
  printf '%s' "$token" | cut -c "1-$_DT_STORY_KEY_MAX"
}

# _dt_generate_handle PERSONA [STORY_KEY] — produce a session-scoped handle.
#
# With a story key (the parallel-aware interface) the handle is a pure function
# of persona and sanitised key: tm-<persona-slug>-<story-key>. No process id
# takes part, which is what lets two same-persona teammates for two different
# stories coexist, and what makes a retry of the same story reuse one handle.
#
# Without a story key the legacy process-id form is kept, and ONLY there: it
# still serves callers of the documented keyless interface. It is never a
# fallback for the keyed path — a keyed spawn that cannot build a keyed handle
# is refused rather than quietly downgraded to a colliding one.
_dt_generate_handle() {
  local persona="$1"
  local story_key="${2:-}"
  local slug
  # LC_ALL=C for the same reason as the story-key sanitiser: the handle must be
  # a pure function of its inputs, not of the caller's locale.
  slug="$(printf '%s' "$persona" | LC_ALL=C tr -c '[:alnum:]' '-')"
  if [ -n "$story_key" ]; then
    printf 'tm-%s-%s' "$slug" "$story_key"
    return 0
  fi
  printf 'tm-%s-%05d' "$slug" "$$"
}

# _dt_substrate_available — return 0 if the live Mode B substrate (persistent
# background Agent + SendMessage) is available, else 1 (→ Mode A fallback).
#
# Resolution order:
#   1. Explicit override GAIA_MODE_B_SUBSTRATE (test/operator force):
#        "available"   → return 0   (force the live path on)
#        "unavailable" → return 1   (force the fallback path; used by
#                                    roster-cost.sh, which never live-spawns,
#                                    AND by operators in a context where the
#                                    spawned-teammate reply leg is known absent —
#                                    see the SendMessage caveat below)
#   2. Otherwise derive from the SAME Agent-Teams capability signal the rest of
#      the framework gates on: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1. That env
#      flag is the user's explicit, knowing opt-in to the experimental Agent
#      Teams substrate (set in settings.json or the environment) — the same flag
#      detect-orchestration-mode.sh requires before it ever returns `team`. When
#      it is set, the substrate is treated as available and Mode B actually runs;
#      when it is absent, the substrate is unavailable and every dispatch
#      degrades to Mode A foreground (the safe default).
#
# This keeps Mode A the default for everyone who has NOT opted in, while making
# the opt-in meaningful: a user who enables the experimental flag (knowing it is
# preview) gets real persistent-teammate dispatch, not a silent fallback. There
# is intentionally no separate "confirmed GA" gate — the experimental flag IS
# the availability contract; graduating it to default-on is a later config-level
# decision, not a second hidden switch here.
#
# SUBSTRATE CAVEAT — the teammate reply leg (KNOWN-INCOMPLETE in some contexts).
# The round-trip's return leg requires the SPAWNED teammate to call
# SendMessage(to: team-lead). That tool is granted to the teammate's context by
# the Claude Code harness, NOT by this library — and it is empirically ABSENT in
# some contexts: a background Agent spawns fine and runs its turn, but cannot
# emit SendMessage, so its reply only comes back as the Agent's terminal return
# value (one task → one return = Mode-A-equivalent semantics, not a persistent
# driven teammate). There is no bash-observable probe for this — only the
# teammate itself can see whether it has the tool. Therefore:
#   - The orchestrator MUST treat a teammate that reports "SendMessage isn't
#     enabled in this context" (or that returns its reply as a terminal Agent
#     result rather than via SendMessage) as a substrate fallback: surface the
#     MODE_B_FALLBACK degradation honestly and continue on the Agent-return
#     (Mode-A-equivalent) path. Do NOT claim a live round-trip occurred.
#   - Operators in a context known to lack the teammate reply leg SHOULD set
#     GAIA_MODE_B_SUBSTRATE=unavailable to force the honest Mode A path up front
#     rather than spawn teammates that cannot complete the round-trip.
# Tracked upstream (Claude Code: teammate context lacks SendMessage). Until the
# harness grants the spawned teammate SendMessage, the env-flag path is
# best-effort spawn, NOT a guaranteed round-trip.
_dt_substrate_available() {
  case "${GAIA_MODE_B_SUBSTRATE:-}" in
    available)   return 0 ;;
    unavailable) return 1 ;;
  esac
  if [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" = "1" ]; then
    return 0
  fi
  return 1
}

# _dt_emit_fallback CALLER — emit the human-readable fallback token on stderr.
# Byte-identical to what it has always emitted, so every consumer that greps
# this token keeps working.
_dt_emit_fallback() {
  printf 'MODE_B_FALLBACK: %s degraded to Mode A foreground dispatch\n' "$1" >&2
}

# _dt_emit_fallback_record STORY_KEY PERSONA REASON — emit the machine-readable
# fallback record on stdout, for story-keyed callers only.
#
# The record is emitted INSTEAD OF a handle, so a caller capturing stdout
# cannot mistake it for one: it does not begin with the handle prefix, and the
# call returns the fallback exit code rather than success. The exit code is the
# control-flow contract (branch on it and degrade to sequential work); this
# record is the diagnostic detail behind it, which the cohort bridge parses and
# republishes to the caller.
_dt_emit_fallback_record() {
  printf 'mode_b_fallback story_key:%s persona:%s reason:%s\n' "$1" "$2" "$3"
}

# _dt_relay_dir — return (and create) the per-session relay-pending directory.
_dt_relay_dir() {
  local dir="${GAIA_SESSION_DIR:?}/relay-pending"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# _dt_set_relay_pending HANDLE — mark that a turn awaits relay.
_dt_set_relay_pending() {
  local handle="$1"
  local dir
  dir="$(_dt_relay_dir)"
  printf '1\n' > "$dir/$handle"
}

# _dt_clear_relay_pending HANDLE — clear the pending relay flag.
_dt_clear_relay_pending() {
  local handle="$1"
  local dir
  dir="$(_dt_relay_dir)"
  rm -f "$dir/$handle"
}

# _dt_is_relay_pending HANDLE — return 0 if a turn awaits relay.
_dt_is_relay_pending() {
  local handle="$1"
  local dir
  dir="$(_dt_relay_dir)"
  [ -f "$dir/$handle" ]
}

# _dt_turn_count_file HANDLE — return the path to the turn counter file.
_dt_turn_count_file() {
  local handle="$1"
  printf '%s' "${GAIA_SESSION_DIR:?}/turns/$handle"
}

# _dt_increment_turn HANDLE — increment and return the turn counter.
_dt_increment_turn() {
  local handle="$1"
  local turns_dir="${GAIA_SESSION_DIR:?}/turns"
  mkdir -p "$turns_dir"
  local count_file="$turns_dir/$handle"
  local current=0
  if [ -f "$count_file" ]; then
    current="$(cat "$count_file")"
  fi
  current=$((current + 1))
  printf '%d' "$current" > "$count_file"
  printf '%d' "$current"
}

# _dt_current_turn HANDLE — return the current turn counter (0 if none).
_dt_current_turn() {
  local handle="$1"
  local count_file
  count_file="$(_dt_turn_count_file "$handle")"
  if [ -f "$count_file" ]; then
    cat "$count_file"
  else
    printf '0'
  fi
}

# Registry-record readers.
#
# Records are line-oriented `field:value` pairs, one line per field, so each of
# these readers takes the FIRST matching line and stops there. Bounding them is
# what keeps a record that is malformed — a legacy file, a partial write, or a
# corrupted one — from returning several lines where a caller expects a scalar:
# an unbounded read would make the same-key retry comparison fail against an
# identical key (refusing a legitimate retry), and would let a second field line
# reach the transcript metadata. Keys are validated at the dispatch boundary so
# a new record cannot contain such a line, but these readers must not depend on
# that to behave deterministically.

# _dt_read_persona HANDLE — read the persona name from the registry file.
_dt_read_persona() {
  local handle="$1"
  _dt_ensure_registry
  if [ -f "$_DT_REGISTRY_DIR/$handle" ]; then
    sed -n '/^persona:/{s/^persona://p;q;}' "$_DT_REGISTRY_DIR/$handle"
  fi
}

# _dt_read_spawn_ts HANDLE — read the spawn timestamp from the registry file.
_dt_read_spawn_ts() {
  local handle="$1"
  _dt_ensure_registry
  if [ -f "$_DT_REGISTRY_DIR/$handle" ]; then
    sed -n '/^spawned:/{s/^spawned://p;q;}' "$_DT_REGISTRY_DIR/$handle"
  fi
}

# _dt_read_story_key HANDLE — read the story key from the registry file.
# Prints nothing for a keyless teammate, which callers render as "none".
_dt_read_story_key() {
  local handle="$1"
  _dt_ensure_registry
  if [ -f "$_DT_REGISTRY_DIR/$handle" ]; then
    sed -n '/^story_key:/{s/^story_key://p;q;}' "$_DT_REGISTRY_DIR/$handle"
  fi
}

# _dt_check_unrelayed_turn HANDLE — if a turn awaits relay, emit WARNING
# and capture a fail-safe entry to the transcript.
_dt_check_unrelayed_turn() {
  local handle="$1"
  if _dt_is_relay_pending "$handle"; then
    printf 'dispatch-teammate: warning: unrelayed turn detected for %s — output may have been lost (fail-safe capture)\n' "$handle" >&2

    local persona spawn_ts turn story_key
    persona="$(_dt_read_persona "$handle")"
    spawn_ts="$(_dt_read_spawn_ts "$handle")"
    turn="$(_dt_current_turn "$handle")"
    story_key="$(_dt_read_story_key "$handle")"

    local transcript="${GAIA_SESSION_TRANSCRIPT:-${GAIA_SESSION_DIR:?}/transcript.md}"
    mkdir -p "$(dirname "$transcript")"
    {
      printf '\n<!-- persona:%s spawn_ts:%s turn:%s story_key:%s -->\n' \
        "${persona:-unknown}" "${spawn_ts:-unknown}" "${turn:-0}" \
        "${story_key:-none}"
      printf '## Unrelayed turn from %s [%s]\n\n' "$handle" "$(_dt_iso8601)"
      printf '[fail-safe capture: teammate turn ended without relay_to_team_lead]\n'
    } >> "$transcript"

    _dt_clear_relay_pending "$handle"
  fi
}

# _dt_log_provenance — append a provenance entry.
_dt_log_provenance() {
  local persona="$1"
  local context="${2:-}"
  local handle="${3:-}"
  local log="${GAIA_PROVENANCE_LOG:-${GAIA_SESSION_DIR:?}/provenance.log}"
  mkdir -p "$(dirname "$log")"
  printf '%s dispatched_via:teammate persona:%s handle:%s context:%s\n' \
    "$(_dt_iso8601)" "$persona" "$handle" "$context" >> "$log"
}

# _dt_corrupt_handle INDEX — corrupt the Nth (1-based) registry handle.
# Test-only helper: replaces the handle file's content with a bad marker.
_dt_corrupt_handle() {
  _dt_ensure_registry
  local idx="$1"
  local files
  files="$(find "$_DT_REGISTRY_DIR" -maxdepth 1 -type f | sort)"
  local target
  target="$(echo "$files" | sed -n "${idx}p")"
  if [ -n "$target" ]; then
    printf 'CORRUPTED\n' > "$target"
  fi
}

# _dt_resolve_reviewer_list — lazily resolve the reviewer-personas.txt path.
_dt_resolve_reviewer_list() {
  if [ -z "$_DT_REVIEWER_PERSONAS" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _DT_REVIEWER_PERSONAS="${lib_dir}/../../knowledge/reviewer-personas.txt"
  fi
}

# _dt_normalize_persona NAME — trim whitespace, strip gaia: prefix (case-insensitive).
# Prints the normalised name on stdout. Pure bash parameter expansion + nocasematch —
# no external process forks (sed/tr), so it is cheap to call in hot loops.
# bash 3.2-safe: nocasematch is available since bash 3.1; ${var,,} is NOT used.
_dt_normalize_persona() {
  local raw="$1"
  # Strip leading whitespace (spaces + tabs).
  raw="${raw#"${raw%%[![:space:]]*}"}"
  # Strip trailing whitespace (spaces + tabs).
  raw="${raw%"${raw##*[![:space:]]}"}"
  # Strip gaia: prefix case-insensitively via nocasematch (bash 3.2-safe; no ${,,}).
  # Save and restore the caller's nocasematch state — this is a sourced library.
  local _saved_nocasematch
  _saved_nocasematch="$(shopt -p nocasematch 2>/dev/null || true)"
  shopt -s nocasematch
  if [[ "$raw" == gaia:* ]]; then
    raw="${raw#*:}"
  fi
  # shellcheck disable=SC2064
  eval "$_saved_nocasematch"
  printf '%s' "$raw"
}

# _dt_is_reviewer PERSONA — return 0 if the persona is a reviewer.
# Normalises the name (strip gaia: prefix, trim whitespace) before matching
# against the list under nocasematch — so case/whitespace/prefix bypass is
# blocked symmetrically on both sides without ${,,} (bash 4+) or tr/sed forks.
# FAIL CLOSED: if the reviewer list is missing or unreadable, returns 0
# (treat as reviewer / blocked) with a diagnostic.
_dt_is_reviewer() {
  local persona="$1"
  local bare
  bare="$(_dt_normalize_persona "$persona")"

  _dt_resolve_reviewer_list

  if [ ! -f "$_DT_REVIEWER_PERSONAS" ] || [ ! -r "$_DT_REVIEWER_PERSONAS" ]; then
    printf 'dispatch-teammate: clean-room list unavailable — refusing to spawn\n' >&2
    return 0
  fi

  # Read the whole list once into an array (single open, no per-line forks),
  # then normalise + compare each entry fully in-process. The read loop is
  # bash 3.2-safe (no mapfile/readarray). nocasematch drives case-insensitive
  # prefix-strip and comparison — no ${,,} bash-4 expansion, no tr/sed forks.
  local _saved_nocasematch
  _saved_nocasematch="$(shopt -p nocasematch 2>/dev/null || true)"
  shopt -s nocasematch

  local entry matched=0
  while IFS= read -r entry; do
    # Trim leading whitespace (spaces + tabs).
    entry="${entry#"${entry%%[![:space:]]*}"}"
    # Skip comments and blank lines.
    case "$entry" in
      '#'*) continue ;;
    esac
    # Trim trailing whitespace.
    entry="${entry%"${entry##*[![:space:]]}"}"
    # Strip gaia: prefix case-insensitively (nocasematch is active).
    if [[ "$entry" == gaia:* ]]; then
      entry="${entry#*:}"
    fi
    [ -z "$entry" ] && continue
    # Compare case-insensitively (nocasematch is active).
    if [[ "$entry" == "$bare" ]]; then
      matched=1
      break
    fi
  done < "$_DT_REVIEWER_PERSONAS"

  # shellcheck disable=SC2064
  eval "$_saved_nocasematch"
  [ "$matched" = "1" ]
}

# _dt_clean_room_gate PERSONA — reject reviewer personas before spawn.
# Returns 0 (pass) or 1 (blocked) with a diagnostic on stderr.
_dt_clean_room_gate() {
  local persona="$1"
  if _dt_is_reviewer "$persona"; then
    local bare="${persona#gaia:}"
    printf 'dispatch-teammate: clean-room violation — "%s" is a reviewer persona and must not be spawned as a teammate (clean-room invariant: reviewers judge from a clean context, never as participants)\n' \
      "$bare" >&2
    return 1
  fi
  return 0
}

# ---------- Frontmatter parser ----------

# _dt_parse_frontmatter SKILL_PATH — parse roster: and topology: from YAML
# frontmatter. Outputs parsed persona names and the effective topology.
_dt_parse_frontmatter() {
  local skill_path="$1"
  if [ ! -f "$skill_path" ]; then
    _dt_die "SKILL.md not found: $skill_path"
    return 1
  fi

  # Extract YAML frontmatter between --- delimiters.
  local in_frontmatter=0
  local frontmatter=""
  while IFS= read -r line; do
    if [ "$in_frontmatter" -eq 0 ]; then
      if [ "$line" = "---" ]; then
        in_frontmatter=1
        continue
      fi
    else
      if [ "$line" = "---" ]; then
        break
      fi
      frontmatter="${frontmatter}${line}
"
    fi
  done < "$skill_path"

  # Parse topology.
  local topology=""
  topology="$(printf '%s' "$frontmatter" | grep -E '^topology:' | head -1 | sed 's/^topology:[[:space:]]*//' | tr -d ' ')"

  # Validate topology.
  local effective_topology="hub"
  case "$topology" in
    hub)  effective_topology="hub" ;;
    mesh) effective_topology="mesh" ;;
    "")   effective_topology="hub" ;;
    *)
      printf 'dispatch-teammate: unrecognised topology value "%s", defaulting to hub\n' "$topology" >&2
      effective_topology="hub"
      ;;
  esac

  # Parse roster entries (persona: lines under roster:).
  local personas=""
  personas="$(printf '%s' "$frontmatter" | grep -E '^\s+persona:' | sed 's/.*persona:[[:space:]]*//')"

  # Output: one persona per line, then topology on the last line.
  if [ -n "$personas" ]; then
    printf '%s\n' "$personas"
  fi
  printf 'topology:%s\n' "$effective_topology"
}

# ---------- Public API ----------

# spawn_teammate PERSONA [--context CTX] [--from-frontmatter SKILL_PATH]
#                        [--story-key KEY]
#
# Spawns a persistent teammate. Returns the session-scoped handle on stdout.
#
# Two interfaces, deliberately:
#   - Keyless (the long-standing form): behaviour is unchanged in every
#     respect. An absent substrate still returns a handle with exit 0 after
#     emitting the stderr token, because callers of this form treat the
#     fallback as advisory.
#   - Story-keyed (--story-key): the parallel-aware form. The handle is built
#     from persona and story key rather than the process id, and an absent
#     substrate is signalled programmatically — the fallback exit code plus a
#     machine-readable record on stdout, and NO handle. Opting into the key is
#     what opts a caller into the stricter contract.
spawn_teammate() {
  local persona="" context="" skill_path="" story_key="" story_keyed=0

  # Parse arguments.
  while [ $# -gt 0 ]; do
    case "$1" in
      # Every value-taking arm checks its arity BEFORE `shift 2`. Under a
      # trailing flag with no value, `shift 2` fails WITHOUT shifting, so the
      # `while [ $# -gt 0 ]` loop below would spin forever on the same argument
      # — a hang rather than an error. Refusing up front turns each of those
      # into an immediate, diagnosable exit.
      --context)
        [ $# -ge 2 ] || { _dt_die "spawn_teammate: --context requires a value"; return 1; }
        context="$2"
        shift 2
        ;;
      --from-frontmatter)
        [ $# -ge 2 ] || { _dt_die "spawn_teammate: --from-frontmatter requires a value"; return 1; }
        skill_path="$2"
        shift 2
        ;;
      # This arm MUST stay ahead of the unknown-flag catch-all below, and MUST
      # consume both the flag and its value. The catch-all shifts only once, so
      # reaching it would leave the key as a positional argument and adopt it
      # as the persona — a silent misdispatch rather than an error.
      --story-key)
        [ $# -ge 2 ] || { _dt_die "spawn_teammate: --story-key requires a value"; return 1; }
        story_key="$2"
        story_keyed=1
        # Validate the RAW key here, at the boundary where it enters the
        # library, and refuse before any sink is touched. Every persistent
        # writer downstream — registry record, transcript metadata comment,
        # fallback record, bridge attribution file — interpolates this value
        # into a structured single-line or comment-delimited format, so this
        # one check is what keeps all of them well-formed.
        _dt_validate_story_key "$story_key" || return 1
        shift 2
        ;;
      --help)
        printf 'Usage: spawn_teammate PERSONA [--context CTX] [--from-frontmatter SKILL_PATH]\n'
        printf '                             [--story-key KEY]\n'
        printf '\n'
        printf '  --story-key KEY  Build the handle from the persona and KEY instead of\n'
        printf '                   the process id, so several same-persona teammates can\n'
        printf '                   run at once. Retrying the same persona and key reuses\n'
        printf '                   the one handle. With this option, an unavailable\n'
        printf '                   substrate returns exit %d and a machine-readable\n' \
          "$_DT_FALLBACK_EXIT_CODE"
        printf '                   record on stdout instead of a handle.\n'
        return 0
        ;;
      -*)
        # Skip unknown flags gracefully.
        shift
        ;;
      *)
        if [ -z "$persona" ]; then
          persona="$1"
        fi
        shift
        ;;
    esac
  done

  if [ -z "$persona" ] && [ -z "$skill_path" ]; then
    _dt_die "spawn_teammate requires a persona name or --from-frontmatter path"
    return 1
  fi

  # Resolve persona from frontmatter if no explicit persona was given.
  if [ -z "$persona" ] && [ -n "$skill_path" ]; then
    local fm_output
    fm_output="$(_dt_parse_frontmatter "$skill_path")" || return 1
    # First non-topology line is the primary persona.
    persona="$(printf '%s\n' "$fm_output" | grep -v '^topology:' | head -1)"
    if [ -z "$persona" ]; then
      _dt_die "spawn_teammate: no persona resolved from frontmatter — cannot spawn"
      return 1
    fi
  elif [ -n "$skill_path" ]; then
    # Explicit persona given alongside --from-frontmatter — parse but keep
    # the explicit name (callers override frontmatter).
    _dt_parse_frontmatter "$skill_path" >/dev/null || true
  fi

  # Clean-room gate — reject reviewer personas BEFORE any spawn attempt.
  # This takes precedence over the ceiling check and Mode B fallback.
  _dt_clean_room_gate "$persona" || return 1

  _dt_ensure_registry

  # Enforce ceiling.
  local count
  count="$(_dt_active_count)"
  if [ "$count" -ge "$_DT_MAX_TEAMMATES" ]; then
    printf 'dispatch-teammate: cannot spawn — %d-teammate ceiling reached (active: %d)\n' \
      "$_DT_MAX_TEAMMATES" "$count" >&2
    return 1
  fi

  if [ "$story_keyed" -eq 1 ]; then
    _dt_spawn_story_keyed "$persona" "$context" "$story_key"
    return $?
  fi

  # Keyless path — unchanged in every respect for existing callers.

  # Generate handle.
  local handle
  handle="$(_dt_generate_handle "$persona")"

  # Ensure unique handle (append counter if collision).
  if [ -f "$_DT_REGISTRY_DIR/$handle" ]; then
    local suffix=1
    while [ -f "$_DT_REGISTRY_DIR/${handle}-${suffix}" ]; do
      suffix=$((suffix + 1))
    done
    handle="${handle}-${suffix}"
  fi

  # Register.
  printf 'persona:%s\nstatus:active\nspawned:%s\n' "$persona" "$(_dt_iso8601)" \
    > "$_DT_REGISTRY_DIR/$handle"

  # Log provenance.
  _dt_log_provenance "$persona" "$context" "$handle"

  # Substrate detection.
  if ! _dt_substrate_available; then
    _dt_emit_fallback "spawn_teammate"
  fi

  # Emit handle on stdout.
  printf '%s\n' "$handle"
}

# _dt_spawn_story_keyed PERSONA CONTEXT STORY_KEY — the story-keyed half of
# spawn_teammate. Kept as its own function so the keyless path above stays
# exactly as it was and the two contracts do not interleave.
#
# Assumes the caller has already run the clean-room gate, the ceiling check and
# _dt_ensure_registry, so a reviewer persona or a ceiling breach is still
# refused with exit 1 and never masked as a fallback.
_dt_spawn_story_keyed() {
  local persona="$1"
  local context="$2"
  local story_key="$3"

  local sanitized
  sanitized="$(_dt_sanitize_story_key "$story_key")"
  if [ -z "$sanitized" ]; then
    # A key of only separators would produce an empty token, and an empty
    # token collapses every story onto one handle — the exact collision this
    # interface exists to remove. Refuse rather than build it.
    _dt_die "spawn_teammate: story key '$story_key' sanitises to nothing — refusing"
    return 1
  fi

  local handle
  handle="$(_dt_generate_handle "$persona" "$sanitized")"

  # Retry contract. The handle is a pure function of persona and key, so a
  # second call for the same story lands on the same handle by construction.
  if [ -f "$_DT_REGISTRY_DIR/$handle" ]; then
    local stored
    stored="$(_dt_read_story_key "$handle")"
    if [ "$stored" != "$story_key" ]; then
      # Two different raw keys reduced to the same token. Suffixing here would
      # hand two stories one attribution lineage, so refuse instead. Comparing
      # the RAW key is what makes this detectable at all.
      _dt_die "spawn_teammate: handle $handle already serves story key '$stored' — refusing '$story_key'"
      return 1
    fi
    # Same story retried: reuse the one handle idempotently. The record is
    # refreshed rather than recreated, so the turn counter and relay-pending
    # state keyed on this handle survive the retry and no orphan is left.
  fi

  # Substrate detection runs BEFORE registration on this path, so a fallback
  # leaves no half-live handle behind for a teammate that was never spawned.
  if ! _dt_substrate_available; then
    _dt_emit_fallback "spawn_teammate"
    _dt_emit_fallback_record "$story_key" "$persona" "substrate-unavailable"
    # Provenance still records the attempt, so the audit trail is complete.
    _dt_log_provenance "$persona" "$context" "(fallback: substrate-unavailable)"
    return "$_DT_FALLBACK_EXIT_CODE"
  fi

  # Register, storing the RAW key: attribution must report what the caller
  # actually passed, and the identity check above needs it to detect a
  # collision. Existing readers match their own field prefixes and are
  # unaffected by the extra line.
  printf 'persona:%s\nstatus:active\nspawned:%s\nstory_key:%s\n' \
    "$persona" "$(_dt_iso8601)" "$story_key" > "$_DT_REGISTRY_DIR/$handle"

  _dt_log_provenance "$persona" "$context" "$handle"

  printf '%s\n' "$handle"
}

# drive_turn HANDLE PROMPT — send a prompt to a teammate.
# drive_turn — PRE-SEND BOOKKEEPING ONLY. This function does NOT send a prompt
# to the teammate, because it cannot: the actual send is the main-turn
# `SendMessage(to: <handle>, ...)` LLM tool call, which a bash script cannot
# invoke. drive_turn's job is to record that the orchestrator is ABOUT TO drive
# a turn — increment the turn counter and raise the relay-pending flag — so the
# transcript-fidelity and unrelayed-turn fail-safe machinery stay consistent.
# The orchestrator procedure (SKILL.md Mode B path) calls drive_turn for
# bookkeeping, THEN emits the SendMessage tool call itself, THEN relays the
# auto-delivered reply via relay_to_team_lead / meeting_relay_turn. The `prompt`
# argument is retained for CLI symmetry and logging but is NOT transmitted here.
drive_turn() {
  local handle="${1:-}"
  local prompt="${2:-}"

  if [ "$handle" = "--help" ]; then
    printf 'Usage: drive_turn HANDLE [PROMPT]\n'
    printf '  Pre-send bookkeeping only (turn counter + relay-pending). Does NOT\n'
    printf '  send — the orchestrator emits the SendMessage tool call after this.\n'
    return 0
  fi

  if [ -z "$handle" ]; then
    _dt_die "drive_turn requires a handle"
    return 1
  fi

  _dt_ensure_registry

  if [ ! -f "$_DT_REGISTRY_DIR/$handle" ]; then
    _dt_die "drive_turn: unknown handle '$handle'"
    return 1
  fi

  # Record the prompt for the provenance log (audit of what the orchestrator is
  # about to SendMessage), when a provenance log is configured. Best-effort.
  if [ -n "$prompt" ] && [ -n "${GAIA_PROVENANCE_LOG:-}" ]; then
    printf '%s drive_turn handle:%s prompt_len:%s\n' \
      "$(_dt_iso8601)" "$handle" "${#prompt}" >> "$GAIA_PROVENANCE_LOG" 2>/dev/null || true
  fi

  # Pre-send bookkeeping: increment the turn counter and raise relay-pending.
  # This always succeeds — it is local state, not a substrate call. There is no
  # substrate gate and no MODE_B_FALLBACK here: drive_turn never sends, so it
  # cannot "fall back". Substrate availability gates the orchestrator's decision
  # to use the Mode B path at all (see spawn_teammate), not this bookkeeping.
  _dt_increment_turn "$handle" >/dev/null
  _dt_set_relay_pending "$handle"

  return 0
}

# await_reply HANDLE — wait for a teammate's reply.
# await_reply — NOT a blocking reply-fetch. A teammate's reply to a SendMessage
# is delivered AUTOMATICALLY into the orchestrator's own conversation ("you
# don't check an inbox") — there is no out-of-band buffer for a bash function to
# block on or read. So await_reply is a BOOKKEEPING QUERY, not a wait: it reports
# whether the just-driven turn is still relay-pending (exit 0 = a reply is
# expected / pending relay; exit 1 = nothing pending). The orchestrator does NOT
# need to call this in the normal flow — it consumes the auto-delivered reply
# directly and calls relay_to_team_lead. await_reply is retained only as a
# state-query helper + so the 6-fn API surface is stable; it MUST NOT be relied
# on to produce a teammate's message.
await_reply() {
  local handle="${1:-}"

  if [ "$handle" = "--help" ]; then
    printf 'Usage: await_reply HANDLE\n'
    printf '  Bookkeeping query only: exit 0 if the turn is relay-pending, else 1.\n'
    printf '  Does NOT block or fetch — teammate replies auto-deliver to the\n'
    printf '  orchestrator; consume them there and call relay_to_team_lead.\n'
    return 0
  fi

  if [ -z "$handle" ]; then
    _dt_die "await_reply requires a handle"
    return 1
  fi

  _dt_ensure_registry

  if [ ! -f "$_DT_REGISTRY_DIR/$handle" ]; then
    _dt_die "await_reply: unknown handle '$handle'"
    return 1
  fi

  # Report relay-pending state; do not block, do not fetch.
  if _dt_is_relay_pending "$handle"; then
    return 0
  fi
  return 1
}

# relay_to_team_lead HANDLE OUTPUT — forward teammate output verbatim to the
# team lead and append it to the session transcript.
relay_to_team_lead() {
  local handle="${1:-}"
  local payload="${2:-}"

  if [ "$handle" = "--help" ]; then
    printf 'Usage: relay_to_team_lead HANDLE OUTPUT\n'
    return 0
  fi

  if [ -z "$handle" ]; then
    _dt_die "relay_to_team_lead requires a handle"
    return 1
  fi

  # Empty output is a no-op — do not append a blank entry.
  if [ -z "$payload" ]; then
    return 0
  fi

  # Read identity metadata for Mode B transcript entries. The story key is
  # appended LAST to the metadata comment, so every pre-existing field keeps
  # its position and readers that match on a named field are unaffected.
  local persona spawn_ts turn story_key
  persona="$(_dt_read_persona "$handle")"
  spawn_ts="$(_dt_read_spawn_ts "$handle")"
  turn="$(_dt_current_turn "$handle")"
  story_key="$(_dt_read_story_key "$handle")"

  # Clear relay-pending flag — this turn has been relayed.
  _dt_clear_relay_pending "$handle"

  # Append to transcript with teammate identity metadata.
  local transcript="${GAIA_SESSION_TRANSCRIPT:-${GAIA_SESSION_DIR:?}/transcript.md}"
  mkdir -p "$(dirname "$transcript")"

  {
    printf '\n<!-- persona:%s spawn_ts:%s turn:%s story_key:%s -->\n' \
      "${persona:-unknown}" "${spawn_ts:-unknown}" "${turn:-0}" \
      "${story_key:-none}"
    printf '## Relay from %s [%s]\n\n' "$handle" "$(_dt_iso8601)"
    printf '%s\n' "$payload"
  } >> "$transcript"

  # relay_to_team_lead is PURE BOOKKEEPING: it appends the (already-received)
  # teammate reply to the transcript with identity metadata and clears the
  # relay-pending flag. It always succeeds and never "falls back" — the reply
  # was already obtained by the orchestrator from the auto-delivered message, so
  # there is no substrate call to gate here.
  return 0
}

# shutdown_teammate HANDLE — shut down a single teammate.
shutdown_teammate() {
  local handle="${1:-}"

  if [ "$handle" = "--help" ]; then
    printf 'Usage: shutdown_teammate HANDLE\n'
    return 0
  fi

  if [ -z "$handle" ]; then
    _dt_die "shutdown_teammate requires a handle"
    return 1
  fi

  _dt_ensure_registry

  if [ ! -f "$_DT_REGISTRY_DIR/$handle" ]; then
    _dt_die "shutdown_teammate: unknown handle '$handle'"
    return 1
  fi

  # Check for corrupted handle (simulated unreachable teammate).
  local first_line
  first_line="$(head -1 "$_DT_REGISTRY_DIR/$handle")"
  if [ "$first_line" = "CORRUPTED" ]; then
    printf 'dispatch-teammate: warning: failed to shut down teammate %s (unreachable)\n' "$handle" >&2
    return 1
  fi

  # Fail-safe: check for unrelayed turn before shutdown.
  _dt_check_unrelayed_turn "$handle"

  # Remove from registry and clean up turn counter.
  rm -f "$_DT_REGISTRY_DIR/$handle"
  local count_file
  count_file="$(_dt_turn_count_file "$handle")"
  rm -f "$count_file"
  return 0
}

# shutdown_all — shut down every active teammate. Idempotent; tolerant of
# individual shutdown failures (partial failure returns non-zero).
shutdown_all() {
  if [ "${1:-}" = "--help" ]; then
    printf 'Usage: shutdown_all\n'
    return 0
  fi

  _dt_ensure_registry

  local count
  count="$(_dt_active_count)"
  if [ "$count" -eq 0 ]; then
    return 0
  fi

  local had_failure=0
  local handle_file handle_name
  for handle_file in "$_DT_REGISTRY_DIR"/*; do
    [ -f "$handle_file" ] || continue
    handle_name="$(basename "$handle_file")"
    if ! shutdown_teammate "$handle_name"; then
      had_failure=1
      printf 'dispatch-teammate: warning: failed to shut down teammate %s\n' "$handle_name" >&2
    fi
  done

  if [ "$had_failure" -eq 1 ]; then
    return 1
  fi
  return 0
}

# ---------- Source guard — mark loaded ----------
_DT_LOADED=1
