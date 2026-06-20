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
# The 8-teammate ceiling is enforced at the registry level.

# ---------- Source guard ----------

if [ "${_DT_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

# ---------- Internal state ----------

# Maximum concurrent teammates.
_DT_MAX_TEAMMATES=8

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

# _dt_generate_handle PERSONA — produce a session-scoped handle.
_dt_generate_handle() {
  local persona="$1"
  local slug
  slug="$(printf '%s' "$persona" | tr -c '[:alnum:]' '-')"
  printf 'tm-%s-%05d' "$slug" "$$"
}

# _dt_substrate_available — return 0 if live Mode B substrate is available.
_dt_substrate_available() {
  # Explicit override for testing.
  if [ "${GAIA_MODE_B_SUBSTRATE:-}" = "unavailable" ]; then
    return 1
  fi
  # In a real runtime, detect whether SendMessage / background Agent are
  # available. For now, default to unavailable — the orchestrator sets the
  # env var when the substrate is confirmed live.
  return 1
}

# _dt_emit_fallback — emit the machine-parseable fallback token once.
_dt_emit_fallback() {
  printf 'MODE_B_FALLBACK: %s degraded to Mode A foreground dispatch\n' "$1" >&2
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

# _dt_normalize_persona NAME — trim whitespace, lowercase, strip gaia: prefix.
# Prints the normalised name on stdout.
_dt_normalize_persona() {
  local raw="$1"
  # Strip leading/trailing whitespace (tabs + spaces).
  raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  # Lowercase first so that GAIA: / Gaia: prefixes are caught.
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  # Strip gaia: prefix if present.
  raw="${raw#gaia:}"
  printf '%s' "$raw"
}

# _dt_is_reviewer PERSONA — return 0 if the persona is a reviewer.
# Normalises the name (strip gaia: prefix, trim whitespace, lowercase) before
# matching against the list. FAIL CLOSED: if the reviewer list is missing or
# unreadable, returns 0 (treat as reviewer / blocked) with a diagnostic.
_dt_is_reviewer() {
  local persona="$1"
  local bare
  bare="$(_dt_normalize_persona "$persona")"

  _dt_resolve_reviewer_list

  if [ ! -f "$_DT_REVIEWER_PERSONAS" ] || [ ! -r "$_DT_REVIEWER_PERSONAS" ]; then
    printf 'dispatch-teammate: clean-room list unavailable — refusing to spawn\n' >&2
    return 0
  fi

  # Normalise each list entry (lowercase + trim) and compare.
  local entry
  while IFS= read -r entry; do
    # Skip comments and blank lines.
    case "$entry" in
      '#'*) continue ;;
    esac
    entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    [ -z "$entry" ] && continue
    if [ "$entry" = "$bare" ]; then
      return 0
    fi
  done < "$_DT_REVIEWER_PERSONAS"
  return 1
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
# Spawns a persistent teammate. Returns the session-scoped handle on stdout.
spawn_teammate() {
  local persona="" context="" skill_path=""

  # Parse arguments.
  while [ $# -gt 0 ]; do
    case "$1" in
      --context)
        context="${2:-}"
        shift 2
        ;;
      --from-frontmatter)
        skill_path="${2:-}"
        shift 2
        ;;
      --help)
        printf 'Usage: spawn_teammate PERSONA [--context CTX] [--from-frontmatter SKILL_PATH]\n'
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

# drive_turn HANDLE PROMPT — send a prompt to a teammate.
drive_turn() {
  local handle="${1:-}"
  # shellcheck disable=SC2034 # prompt consumed by live substrate path
  local prompt="${2:-}"

  if [ "$handle" = "--help" ]; then
    printf 'Usage: drive_turn HANDLE PROMPT\n'
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

  # Substrate detection.
  if ! _dt_substrate_available; then
    _dt_emit_fallback "drive_turn"
    return 0
  fi

  # Live substrate path — placeholder for SendMessage dispatch.
  return 0
}

# await_reply HANDLE — wait for a teammate's reply.
await_reply() {
  local handle="${1:-}"

  if [ "$handle" = "--help" ]; then
    printf 'Usage: await_reply HANDLE\n'
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

  # Substrate detection.
  if ! _dt_substrate_available; then
    _dt_emit_fallback "await_reply"
    return 0
  fi

  # Live substrate path — placeholder for reply retrieval.
  return 0
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

  # Append to transcript.
  local transcript="${GAIA_SESSION_TRANSCRIPT:-${GAIA_SESSION_DIR:?}/transcript.md}"
  mkdir -p "$(dirname "$transcript")"

  {
    printf '\n## Relay from %s [%s]\n\n' "$handle" "$(_dt_iso8601)"
    printf '%s\n' "$payload"
  } >> "$transcript"

  # Substrate detection.
  if ! _dt_substrate_available; then
    _dt_emit_fallback "relay_to_team_lead"
  fi

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

  # Remove from registry.
  rm -f "$_DT_REGISTRY_DIR/$handle"
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
    if ! shutdown_teammate "$handle_name" 2>/dev/null; then
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
