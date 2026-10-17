#!/usr/bin/env bash
# session-binding.sh — session-to-sprint binding helpers.
#
# Provides binding-dir provisioning, binding lifecycle (write, read,
# validate), and a CLI entry point (`session-binding.sh read`).
#
# The binding file lives at $GAIA_BINDING_DIR/bound_sprint_id.
# It is write-once (noclobber) and read on every call.
#
# Exit codes for read_binding() and the `read` CLI entry point:
#   0 — bound (prints sprint id; sprint is active, review, or correction)
#   1 — no binding (unbound or single-sprint mode)
#   2 — bound sprint is closed (prints id, stderr message)
#   3 — invalid or spoofed binding (unsafe id, containment failure, malformed)
#
# Usage:
#   source session-binding.sh    # makes functions available
#   session-binding.sh read      # CLI: print binding state
#   session-binding.sh read --session-id <id> --project-root <path>

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Constants ----------

_SB_BINDING_FILENAME="bound_sprint_id"
_SB_SESSION_DIR_NAME="sessions"
_SB_STATE_SUBDIR=".gaia/state"
_SB_SCRIPT_NAME="${0##*/}"

# ---------- Realpath helper ----------

# Portable realpath: use the `realpath` command when available, fall back to
# `python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))'`, then
# `cd + pwd -P`.
_sb_realpath() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null && return 0
  fi
  # Fallback: cd + pwd for directories; for files, resolve the parent.
  if [ -d "$p" ]; then
    (cd "$p" && pwd -P) 2>/dev/null && return 0
  elif [ -e "$p" ]; then
    local dir base rdir
    dir="$(dirname "$p")"
    base="$(basename "$p")"
    rdir="$(cd "$dir" && pwd -P)" 2>/dev/null || return 1
    printf '%s/%s' "$rdir" "$base"
    return 0
  fi
  # Path does not exist — resolve the parent if it exists.
  local dir base rdir
  dir="$(dirname "$p")"
  base="$(basename "$p")"
  if [ -d "$dir" ]; then
    rdir="$(cd "$dir" && pwd -P)" 2>/dev/null || return 1
    printf '%s/%s' "$rdir" "$base"
    return 0
  fi
  printf '%s' "$p"
}

# ---------- Session ID derivation ----------

# Derive the session ID from the environment. Prefers CLAUDE_CODE_SESSION_ID,
# falls back to CLAUDE_SESSION_ID (same precedent as yolo-mode.sh).
# Arguments override env:
#   _sb_derive_session_id [--session-id <id>]
# Prints the ID on stdout; returns 1 with a diagnostic on failure.
_sb_derive_session_id() {
  local explicit_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-id) shift; explicit_id="${1:-}"; shift || true ;;
      *) shift ;;
    esac
  done

  local sid=""
  if [ -n "$explicit_id" ]; then
    sid="$explicit_id"
  else
    sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  fi

  if [ -z "$sid" ]; then
    printf '%s: error: no session identity — set CLAUDE_CODE_SESSION_ID or CLAUDE_SESSION_ID\n' \
      "$_SB_SCRIPT_NAME" >&2
    return 1
  fi

  printf '%s' "$sid"
}

# Validate a session ID for filesystem safety.
# Rejects: empty, path separators, NUL (bash truncates), leading dot,
# whitespace, control characters.
_sb_validate_session_id() {
  local sid="$1"

  if [ -z "$sid" ]; then
    printf '%s: error: session ID is empty\n' "$_SB_SCRIPT_NAME" >&2
    return 1
  fi

  # Path separators (/ or \).
  case "$sid" in
    */*|*\\*)
      printf '%s: error: session ID contains path separator: %s\n' \
        "$_SB_SCRIPT_NAME" "$sid" >&2
      return 1 ;;
  esac

  # Leading dot.
  case "$sid" in
    .*)
      printf '%s: error: session ID starts with a leading dot: %s\n' \
        "$_SB_SCRIPT_NAME" "$sid" >&2
      return 1 ;;
  esac

  # Whitespace (space, tab, newline, carriage return).
  if printf '%s' "$sid" | /usr/bin/grep -q '[[:space:]]'; then
    printf '%s: error: session ID contains whitespace: %s\n' \
      "$_SB_SCRIPT_NAME" "$sid" >&2
    return 1
  fi

  # Control characters (ASCII 0x00-0x1F, 0x7F).
  if printf '%s' "$sid" | /usr/bin/grep -q '[[:cntrl:]]'; then
    printf '%s: error: session ID contains control characters: %s\n' \
      "$_SB_SCRIPT_NAME" "$sid" >&2
    return 1
  fi

  return 0
}

# ---------- Project root resolution ----------

# Resolve the project root. Order:
#   --project-root > CLAUDE_PROJECT_ROOT / PROJECT_ROOT > walk up from CWD.
_sb_resolve_project_root() {
  local explicit_root=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project-root) shift; explicit_root="${1:-}"; shift || true ;;
      *) shift ;;
    esac
  done

  if [ -n "$explicit_root" ]; then
    printf '%s' "$explicit_root"
    return 0
  fi

  local root="${CLAUDE_PROJECT_ROOT:-${PROJECT_ROOT:-}}"
  if [ -n "$root" ]; then
    printf '%s' "$root"
    return 0
  fi

  # Walk up from CWD to find .gaia/state/.
  local dir
  dir="$(pwd)"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/$_SB_STATE_SUBDIR" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  printf '%s: error: cannot resolve project root (no .gaia/state/ found)\n' \
    "$_SB_SCRIPT_NAME" >&2
  return 1
}

# ---------- Binding-dir provisioning ----------

# Provision (or validate) the binding directory for the current session.
# Exports GAIA_BINDING_DIR.
#
# Arguments (optional, passed through from CLI):
#   --session-id <id>
#   --project-root <path>
#
# Returns 0 on success, 1 on invalid session ID, 3 on spoofing.
provision_binding_dir() {
  local sid="" project_root=""

  sid="$(_sb_derive_session_id "$@")" || return 1
  _sb_validate_session_id "$sid" || return 1

  project_root="$(_sb_resolve_project_root "$@")" || return 1

  local derived_dir="${project_root%/}/${_SB_STATE_SUBDIR}/${_SB_SESSION_DIR_NAME}/${sid}"

  # Create the directory if absent.
  if [ ! -d "$derived_dir" ]; then
    mkdir -p "$derived_dir" 2>/dev/null || true
    chmod 0700 "$derived_dir" 2>/dev/null || true
  fi

  local derived_real=""
  derived_real="$(_sb_realpath "$derived_dir")" || derived_real="$derived_dir"

  # Validate inherited GAIA_BINDING_DIR if set.
  if [ -n "${GAIA_BINDING_DIR:-}" ]; then
    local inherited_real=""
    inherited_real="$(_sb_realpath "$GAIA_BINDING_DIR")" || inherited_real="$GAIA_BINDING_DIR"
    if [ "$inherited_real" != "$derived_real" ]; then
      printf '%s: error: inherited GAIA_BINDING_DIR does not match derived path (spoofing detected)\n' \
        "$_SB_SCRIPT_NAME" >&2
      printf '%s: inherited=%s derived=%s\n' "$_SB_SCRIPT_NAME" "$inherited_real" "$derived_real" >&2
      return 3
    fi
  fi

  GAIA_BINDING_DIR="$derived_dir"
  export GAIA_BINDING_DIR
  return 0
}

# ---------- Sprint status check ----------

# Check sprint status from its per-sprint state file.
# Returns: prints the status (active, review, correction, closed, planned).
_sb_sprint_status() {
  local sprint_id="$1" state_dir="$2"
  local sprint_file="${state_dir}/sprint-status-${sprint_id}.yaml"

  if [ ! -f "$sprint_file" ]; then
    # Fall back to the single-file layout.
    sprint_file="${state_dir}/sprint-status.yaml"
    if [ ! -f "$sprint_file" ]; then
      printf 'missing'
      return 0
    fi
    # Check if this sprint ID is in the single file.
    local file_sid=""
    file_sid="$(yq '.sprint_id' "$sprint_file" 2>/dev/null)" || file_sid=""
    if [ "$file_sid" != "$sprint_id" ]; then
      printf 'missing'
      return 0
    fi
  fi

  local status=""
  status="$(yq '.status' "$sprint_file" 2>/dev/null)" || status=""
  if [ -z "$status" ] || [ "$status" = "null" ]; then
    printf 'missing'
    return 0
  fi
  printf '%s' "$status"
}

# ---------- Binding lifecycle functions ----------

# write_binding — create the binding file (write-once via noclobber).
#
# Arguments:
#   $1 — sprint ID to bind to
#   $2 — state directory (containing sprint-status-*.yaml files)
#
# Preconditions:
#   - GAIA_BINDING_DIR must be set and provisioned.
#   - Sprint must be active (not closed, not planned).
#
# Returns 0 on success, 1 on validation failure, 2 on already-bound-different.
write_binding() {
  local sprint_id="$1"
  local state_dir="$2"
  local binding_file="${GAIA_BINDING_DIR}/${_SB_BINDING_FILENAME}"

  # Validate the sprint ID format.
  if [ -z "$sprint_id" ]; then
    printf '%s: error: sprint ID is required for binding\n' "$_SB_SCRIPT_NAME" >&2
    return 1
  fi
  if printf '%s' "$sprint_id" | /usr/bin/grep -q '[^A-Za-z0-9._-]'; then
    printf '%s: error: sprint ID contains invalid characters: %s\n' "$_SB_SCRIPT_NAME" "$sprint_id" >&2
    return 1
  fi
  case "${sprint_id:0:1}" in
    [A-Za-z0-9]) : ;;
    *)
      printf '%s: error: sprint ID must start with an alphanumeric character: %s\n' \
        "$_SB_SCRIPT_NAME" "$sprint_id" >&2
      return 1 ;;
  esac

  # Check the sprint exists and is active.
  local status=""
  status="$(_sb_sprint_status "$sprint_id" "$state_dir")"
  case "$status" in
    active) : ;;  # Only active sprints can be bound.
    closed)
      printf '%s: error: sprint %s is closed — cannot bind to a closed sprint\n' \
        "$_SB_SCRIPT_NAME" "$sprint_id" >&2
      return 1 ;;
    planned)
      printf '%s: error: sprint %s is planned — only active sprints can be bound\n' \
        "$_SB_SCRIPT_NAME" "$sprint_id" >&2
      return 1 ;;
    missing)
      printf '%s: error: sprint %s does not exist\n' "$_SB_SCRIPT_NAME" "$sprint_id" >&2
      return 1 ;;
    *)
      printf '%s: error: sprint %s has unexpected status: %s\n' \
        "$_SB_SCRIPT_NAME" "$sprint_id" "$status" >&2
      return 1 ;;
  esac

  # If binding file already exists, check for re-entry or conflict.
  if [ -f "$binding_file" ]; then
    local existing=""
    existing="$(cat "$binding_file" 2>/dev/null | tr -d '\n')" || existing=""

    # Containment check on existing file.
    if ! _sb_check_containment "$binding_file"; then
      return 3
    fi

    if [ "$existing" = "$sprint_id" ]; then
      # Idempotent re-entry: same sprint, reuse binding.
      return 0
    else
      printf '%s: error: already bound to %s\n' "$_SB_SCRIPT_NAME" "$existing" >&2
      return 2
    fi
  fi

  # Write the binding file atomically via noclobber.
  ( set -C; printf '%s' "$sprint_id" > "$binding_file" ) 2>/dev/null
  local rc=$?
  if [ $rc -ne 0 ]; then
    # noclobber refused — another process created the file.
    if [ -f "$binding_file" ]; then
      local existing=""
      existing="$(cat "$binding_file" 2>/dev/null | tr -d '\n')" || existing=""
      if [ "$existing" = "$sprint_id" ]; then
        return 0  # Same sprint — idempotent.
      fi
      printf '%s: error: already bound to %s\n' "$_SB_SCRIPT_NAME" "$existing" >&2
      return 2
    fi
    printf '%s: error: failed to write binding file\n' "$_SB_SCRIPT_NAME" >&2
    return 1
  fi

  return 0
}

# read_binding — read the current binding state.
#
# Exit codes:
#   0 — bound (prints sprint id; sprint is active, review, or correction)
#   1 — no binding (no file or single-sprint mode)
#   2 — bound sprint is closed (prints id, stderr message)
#   3 — invalid binding (malformed file, containment failure)
read_binding() {
  local binding_file="${GAIA_BINDING_DIR:-}/${_SB_BINDING_FILENAME}"

  # No binding dir or file — unbound.
  if [ -z "${GAIA_BINDING_DIR:-}" ] || [ ! -f "$binding_file" ]; then
    return 1
  fi

  # Containment check.
  if ! _sb_check_containment "$binding_file"; then
    return 3
  fi

  # Read the binding.
  local bound_id=""
  bound_id="$(cat "$binding_file" 2>/dev/null | tr -d '\n')" || bound_id=""

  # Validate format.
  if [ -z "$bound_id" ]; then
    printf '%s: error: binding file is empty\n' "$_SB_SCRIPT_NAME" >&2
    return 3
  fi
  if printf '%s' "$bound_id" | /usr/bin/grep -q '[^A-Za-z0-9._-]'; then
    printf '%s: error: binding file contains invalid sprint ID: %s\n' \
      "$_SB_SCRIPT_NAME" "$bound_id" >&2
    return 3
  fi

  # Resolve the state directory for status check.
  local state_dir=""
  local project_root="${CLAUDE_PROJECT_ROOT:-${PROJECT_ROOT:-}}"
  if [ -n "$project_root" ]; then
    state_dir="${project_root%/}/${_SB_STATE_SUBDIR}"
  elif [ -n "${GAIA_BINDING_DIR:-}" ]; then
    # Walk up from binding dir: .gaia/state/sessions/<id>/ -> .gaia/state/
    state_dir="$(dirname "$(dirname "${GAIA_BINDING_DIR}")")"
  fi

  if [ -z "$state_dir" ] || [ ! -d "$state_dir" ]; then
    # Cannot check status — treat as valid but warn.
    printf '%s' "$bound_id"
    return 0
  fi

  # Check sprint status.
  local status=""
  status="$(_sb_sprint_status "$bound_id" "$state_dir")"
  case "$status" in
    active|review|correction)
      printf '%s' "$bound_id"
      return 0 ;;
    closed)
      printf '%s' "$bound_id"
      printf '%s: bound sprint %s is closed\n' "$_SB_SCRIPT_NAME" "$bound_id" >&2
      return 2 ;;
    *)
      printf '%s' "$bound_id"
      printf '%s: warning: bound sprint %s has status %s\n' \
        "$_SB_SCRIPT_NAME" "$bound_id" "$status" >&2
      return 3 ;;
  esac
}

# validate_binding — cross-validate env var against binding file.
#
# Called before state-mutating operations. Halts with binding_mismatch
# when the env var disagrees with the file.
#
# Returns 0 on match, 1 on mismatch.
validate_binding() {
  local binding_file="${GAIA_BINDING_DIR:-}/${_SB_BINDING_FILENAME}"

  # If no env var is set and no binding file exists, nothing to validate.
  if [ -z "${GAIA_BOUND_SPRINT_ID:-}" ] && { [ -z "${GAIA_BINDING_DIR:-}" ] || [ ! -f "$binding_file" ]; }; then
    return 0
  fi

  # If env var is set but no binding file: mismatch.
  if [ -n "${GAIA_BOUND_SPRINT_ID:-}" ] && { [ -z "${GAIA_BINDING_DIR:-}" ] || [ ! -f "$binding_file" ]; }; then
    printf '%s: error: binding_mismatch — GAIA_BOUND_SPRINT_ID is set (%s) but no binding file exists\n' \
      "$_SB_SCRIPT_NAME" "$GAIA_BOUND_SPRINT_ID" >&2
    return 1
  fi

  # Read the binding file.
  local file_id=""
  file_id="$(cat "$binding_file" 2>/dev/null | tr -d '\n')" || file_id=""

  # If env var is set and differs from the file: mismatch.
  if [ -n "${GAIA_BOUND_SPRINT_ID:-}" ] && [ "$GAIA_BOUND_SPRINT_ID" != "$file_id" ]; then
    printf '%s: error: binding_mismatch — env GAIA_BOUND_SPRINT_ID=%s differs from binding file=%s\n' \
      "$_SB_SCRIPT_NAME" "$GAIA_BOUND_SPRINT_ID" "$file_id" >&2
    return 1
  fi

  return 0
}

# ---------- Containment check ----------

# Verify the binding file path resides within GAIA_BINDING_DIR.
_sb_check_containment() {
  local file_path="$1"
  local dir_real="" file_real=""

  dir_real="$(_sb_realpath "${GAIA_BINDING_DIR}")" || dir_real="$GAIA_BINDING_DIR"
  file_real="$(_sb_realpath "$file_path")" || file_real="$file_path"

  # The file's realpath must start with the dir's realpath.
  case "$file_real" in
    "${dir_real}"|"${dir_real}"/*)
      return 0 ;;
    *)
      printf '%s: error: binding file path escapes binding directory (containment failure)\n' \
        "$_SB_SCRIPT_NAME" >&2
      printf '%s: dir=%s file=%s\n' "$_SB_SCRIPT_NAME" "$dir_real" "$file_real" >&2
      return 1 ;;
  esac
}

# ---------- CLI entry point ----------

# Direct invocation: session-binding.sh read [--session-id <id>] [--project-root <path>]
_sb_cli() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    read)
      # Parse CLI options.
      local cli_session_id="" cli_project_root=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --session-id) shift; cli_session_id="${1:-}"; shift || true ;;
          --project-root) shift; cli_project_root="${1:-}"; shift || true ;;
          *) shift ;;
        esac
      done

      # Build provision args.
      local prov_args=()
      [ -n "$cli_session_id" ] && prov_args+=(--session-id "$cli_session_id")
      [ -n "$cli_project_root" ] && prov_args+=(--project-root "$cli_project_root")

      provision_binding_dir "${prov_args[@]+"${prov_args[@]}"}" || return $?
      read_binding
      return $?
      ;;
    "")
      printf '%s: error: subcommand required (e.g. "read")\n' "$_SB_SCRIPT_NAME" >&2
      return 1 ;;
    *)
      printf '%s: error: unknown subcommand: %s\n' "$_SB_SCRIPT_NAME" "$subcmd" >&2
      return 1 ;;
  esac
}

# Run CLI only when executed directly (not sourced).
if [ "${BASH_SOURCE[0]}" = "$0" ] 2>/dev/null || [ "${0##*/}" = "session-binding.sh" ]; then
  _sb_cli "$@"
fi
