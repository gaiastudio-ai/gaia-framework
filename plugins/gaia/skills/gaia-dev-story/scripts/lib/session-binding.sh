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

  # Length cap (64 characters, aligned with the statusline runtime limit).
  if [ "${#sid}" -gt 64 ]; then
    printf '%s: error: session ID exceeds 64-character limit (%d chars)\n' \
      "$_SB_SCRIPT_NAME" "${#sid}" >&2
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

  # Walk up from CWD to find the state directory.
  local dir
  dir="$(pwd)"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.gaia/state" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  printf '%s: error: cannot resolve project root (no state directory found)\n' \
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

  local derived_dir="${project_root%/}/.gaia/state/${_SB_SESSION_DIR_NAME}/${sid}"

  # Create the directory if absent, detecting failures instead of swallowing them.
  if [ ! -d "$derived_dir" ]; then
    if ! mkdir -p "$derived_dir" 2>/dev/null; then
      printf '%s: error: mkdir failed for binding directory: %s\n' \
        "$_SB_SCRIPT_NAME" "$derived_dir" >&2
      return 1
    fi
    if ! chmod 0700 "$derived_dir" 2>/dev/null; then
      printf '%s: error: chmod 0700 failed for binding directory: %s\n' \
        "$_SB_SCRIPT_NAME" "$derived_dir" >&2
      return 1
    fi
    # Post-check: confirm the directory exists with the correct mode.
    if [ ! -d "$derived_dir" ]; then
      printf '%s: error: binding directory absent after creation: %s\n' \
        "$_SB_SCRIPT_NAME" "$derived_dir" >&2
      return 1
    fi
    local _sb_mode=""
    _sb_mode="$(stat -f '%Lp' "$derived_dir" 2>/dev/null || stat -c '%a' "$derived_dir" 2>/dev/null || echo "")"
    if [ "$_sb_mode" != "700" ]; then
      printf '%s: error: binding directory mode is %s, expected 700: %s\n' \
        "$_SB_SCRIPT_NAME" "$_sb_mode" "$derived_dir" >&2
      return 1
    fi
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
    state_dir="${project_root%/}/.gaia/state"
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

# ---------- Sprint-arg exit codes ----------

SPRINT_NOT_FOUND=10
SPRINT_REFUSED_CLOSED=11
SPRINT_AMBIGUOUS=12
SPRINT_REPEATED_ARG=13
SPRINT_POSITIONAL_CONFLICT=14
SPRINT_BOUND_MISMATCH=15
SPRINT_INVALID_ID=16
SPRINT_BOUND_CLOSED=17

# ---------- Sprint-arg command class table ----------

# Command classes:
#   read-only        — accepts any sprint state (including closed/archived)
#   mutating         — refuses closed sprints (per-command exceptions below)
#   sprint-optional  — never refuses for ambiguity or closed state
#   run-sprint       — refuses --sprint that differs from the binding
#
# Per-command exceptions:
#   sprint-close   — closed sprint returns exit 0 (idempotent/resume)
#   sprint-review  — closed sprint returns exit 0 (historical read-only)
#   action-items   — sprint-optional, never refuses
_rsa_command_class() {
  local cmd="$1"
  case "$cmd" in
    sprint-status)    printf 'read-only' ;;
    sprint-close)     printf 'mutating' ;;
    sprint-review)    printf 'mutating' ;;
    retro)            printf 'mutating' ;;
    correct-course)   printf 'mutating' ;;
    sprint-plan)      printf 'mutating' ;;
    run-sprint)       printf 'run-sprint' ;;
    action-items)     printf 'sprint-optional' ;;
    *)
      printf '%s: error: unknown command class for: %s\n' "$_SB_SCRIPT_NAME" "$cmd" >&2
      return 1 ;;
  esac
}

# ---------- Sprint-arg archive lookup ----------

# Check if a sprint exists in the archive directory.
# Prints the archive file path if found, empty string otherwise.
_rsa_find_archive() {
  local sprint_id="$1" state_dir="$2"
  local archive_dir=""
  local project_root=""
  project_root="${CLAUDE_PROJECT_ROOT:-${PROJECT_ROOT:-}}"
  if [ -n "$project_root" ]; then
    archive_dir="${project_root%/}/.gaia/artifacts/implementation-artifacts/sprint-archive"
  elif [ -n "$state_dir" ]; then
    # Derive: .gaia/state -> .gaia/artifacts/implementation-artifacts/sprint-archive
    local gaia_dir=""
    gaia_dir="$(dirname "$state_dir")"
    archive_dir="${gaia_dir}/artifacts/implementation-artifacts/sprint-archive"
  fi
  if [ -z "$archive_dir" ] || [ ! -d "$archive_dir" ]; then
    return 0
  fi
  # Archive naming: {sprint_id}-closed-{date}.yaml
  local found=""
  found="$(find "$archive_dir" -maxdepth 1 -name "${sprint_id}-closed-*.yaml" 2>/dev/null | head -1)" || found=""
  if [ -n "$found" ]; then
    printf '%s' "$found"
  fi
}

# ---------- Sprint-arg active sprint enumeration ----------

# List all active sprint IDs (one per line). Scans per-sprint state files.
# Falls back to the single-file layout when no per-sprint files exist.
_rsa_list_active_sprints() {
  local state_dir="$1"
  [ -d "$state_dir" ] || return 0

  local found_any=false
  local f sid status
  for f in "$state_dir"/sprint-status-*.yaml; do
    [ -f "$f" ] || continue
    # Skip lock/result files
    case "$f" in *.lock|*.result) continue ;; esac
    sid="$(yq '.sprint_id // ""' "$f" 2>/dev/null)" || sid=""
    [ -z "$sid" ] || [ "$sid" = "null" ] && continue
    status="$(yq '.status // ""' "$f" 2>/dev/null)" || status=""
    case "$status" in
      active|review|correction)
        printf '%s\n' "$sid"
        found_any=true ;;
    esac
  done

  # Fallback to the single-file layout
  if [ "$found_any" = false ]; then
    local single="${state_dir}/sprint-status.yaml"
    if [ -f "$single" ]; then
      sid="$(yq '.sprint_id // ""' "$single" 2>/dev/null)" || sid=""
      status="$(yq '.status // ""' "$single" 2>/dev/null)" || status=""
      if [ -n "$sid" ] && [ "$sid" != "null" ]; then
        case "$status" in
          active|review|correction)
            printf '%s\n' "$sid" ;;
        esac
      fi
    fi
  fi
}

# ---------- resolve_sprint_arg ----------

# Resolve the target sprint ID from --sprint, positional args, session
# binding, or single-sprint default.
#
# Usage:
#   resolve_sprint_arg --command <name> [--sprint <id>] [--new-sprint <id>] [positional ...]
#
# Prints the resolved sprint ID on stdout.
# Exit codes: see SPRINT_* constants above.
resolve_sprint_arg() {
  local command_name=""
  local sprint_arg=""
  local sprint_arg_count=0
  local new_sprint_arg=""
  local positional=""

  # --- Parse arguments ---
  while [ $# -gt 0 ]; do
    case "$1" in
      --command)
        shift
        command_name="${1:-}"
        [ -z "$command_name" ] && {
          printf '%s: error: --command requires a value\n' "$_SB_SCRIPT_NAME" >&2
          return 1
        }
        shift ;;
      --sprint)
        shift
        local val="${1:-}"
        # Empty value check
        if [ -z "$val" ]; then
          printf '%s: error: --sprint requires a non-empty value\n' "$_SB_SCRIPT_NAME" >&2
          return "$SPRINT_INVALID_ID"
        fi
        sprint_arg_count=$((sprint_arg_count + 1))
        if [ "$sprint_arg_count" -gt 1 ]; then
          printf '%s: error: repeated --sprint: "%s" and "%s"\n' \
            "$_SB_SCRIPT_NAME" "$sprint_arg" "$val" >&2
          return "$SPRINT_REPEATED_ARG"
        fi
        sprint_arg="$val"
        shift ;;
      --new-sprint)
        shift
        new_sprint_arg="${1:-}"
        [ -z "$new_sprint_arg" ] && {
          printf '%s: error: --new-sprint requires a non-empty value\n' "$_SB_SCRIPT_NAME" >&2
          return "$SPRINT_INVALID_ID"
        }
        shift ;;
      --project-root|--session-id)
        shift; shift || true ;;  # consumed by other helpers
      --)
        shift; break ;;
      -*)
        shift ;;  # skip unknown flags
      *)
        # Positional argument — only retro and sprint-review forward these
        if [ -z "$positional" ]; then
          positional="$1"
        fi
        shift ;;
    esac
  done

  if [ -z "$command_name" ]; then
    printf '%s: error: --command is required\n' "$_SB_SCRIPT_NAME" >&2
    return 1
  fi

  # --- Validate the command class ---
  local cmd_class=""
  cmd_class="$(_rsa_command_class "$command_name")" || return 1

  # --- Resolve the state directory ---
  local state_dir=""
  local project_root="${CLAUDE_PROJECT_ROOT:-${PROJECT_ROOT:-}}"
  if [ -n "$project_root" ]; then
    state_dir="${project_root%/}/.gaia/state"
  fi
  if [ -z "$state_dir" ] || [ ! -d "$state_dir" ]; then
    printf '%s: error: cannot resolve state directory\n' "$_SB_SCRIPT_NAME" >&2
    return 1
  fi

  # --- New-sprint class (sprint-plan --new-sprint) ---
  if [ -n "$new_sprint_arg" ]; then
    # Validate ID shape
    if ! printf '%s' "$new_sprint_arg" | /usr/bin/grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
      printf '%s: error: invalid sprint ID shape: %s\n' "$_SB_SCRIPT_NAME" "$new_sprint_arg" >&2
      return "$SPRINT_INVALID_ID"
    fi
    # Check unused: not in any state file or archive
    local ns_status=""
    ns_status="$(_sb_sprint_status "$new_sprint_arg" "$state_dir")"
    if [ "$ns_status" != "missing" ]; then
      printf '%s: error: sprint ID already exists: %s (status: %s)\n' \
        "$_SB_SCRIPT_NAME" "$new_sprint_arg" "$ns_status" >&2
      return "$SPRINT_INVALID_ID"
    fi
    local ns_archive=""
    ns_archive="$(_rsa_find_archive "$new_sprint_arg" "$state_dir")"
    if [ -n "$ns_archive" ]; then
      printf '%s: error: sprint ID already exists in archive: %s\n' \
        "$_SB_SCRIPT_NAME" "$new_sprint_arg" >&2
      return "$SPRINT_INVALID_ID"
    fi
    printf '%s' "$new_sprint_arg"
    return 0
  fi

  # --- Validate sprint_arg format (if provided) ---
  if [ -n "$sprint_arg" ]; then
    if ! printf '%s' "$sprint_arg" | /usr/bin/grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
      printf '%s: error: invalid sprint ID: %s\n' "$_SB_SCRIPT_NAME" "$sprint_arg" >&2
      return "$SPRINT_INVALID_ID"
    fi
  fi

  # --- Positional conflict check ---
  # Only retro and sprint-review forward positional args
  if [ -n "$positional" ]; then
    case "$command_name" in
      retro|sprint-review)
        if [ -n "$sprint_arg" ] && [ "$positional" != "$sprint_arg" ]; then
          printf '%s: error: positional sprint ID "%s" conflicts with --sprint "%s"\n' \
            "$_SB_SCRIPT_NAME" "$positional" "$sprint_arg" >&2
          return "$SPRINT_POSITIONAL_CONFLICT"
        fi
        # If no --sprint but has positional, use it
        if [ -z "$sprint_arg" ]; then
          sprint_arg="$positional"
        fi
        ;;
    esac
  fi

  # --- Read the session binding ---
  local bound_id=""
  local binding_closed=false
  if [ -n "${GAIA_BOUND_SPRINT_ID:-}" ]; then
    bound_id="$GAIA_BOUND_SPRINT_ID"
    # Check if the bound sprint is closed
    local bs_status=""
    bs_status="$(_sb_sprint_status "$bound_id" "$state_dir")"
    if [ "$bs_status" = "closed" ]; then
      binding_closed=true
    fi
  elif [ -n "${GAIA_BINDING_DIR:-}" ] && [ -f "${GAIA_BINDING_DIR}/${_SB_BINDING_FILENAME}" ]; then
    bound_id="$(cat "${GAIA_BINDING_DIR}/${_SB_BINDING_FILENAME}" 2>/dev/null | tr -d '\n')" || bound_id=""
    if [ -n "$bound_id" ]; then
      local bs_status=""
      bs_status="$(_sb_sprint_status "$bound_id" "$state_dir")"
      if [ "$bs_status" = "closed" ]; then
        binding_closed=true
      fi
    fi
  fi

  # --- Sprint-optional class: early return ---
  if [ "$cmd_class" = "sprint-optional" ]; then
    if [ -n "$sprint_arg" ]; then
      # Validate the sprint exists (state file or archive)
      local so_status=""
      so_status="$(_sb_sprint_status "$sprint_arg" "$state_dir")"
      if [ "$so_status" = "missing" ]; then
        local so_archive=""
        so_archive="$(_rsa_find_archive "$sprint_arg" "$state_dir")"
        if [ -z "$so_archive" ]; then
          printf '%s: error: sprint not found: %s\n' "$_SB_SCRIPT_NAME" "$sprint_arg" >&2
          return "$SPRINT_NOT_FOUND"
        fi
      fi
      printf '%s' "$sprint_arg"
      return 0
    fi
    # No --sprint: return empty (operates on all items)
    return 0
  fi

  # --- Determine the target sprint ID ---
  local target_id=""
  if [ -n "$sprint_arg" ]; then
    target_id="$sprint_arg"
  elif [ "$cmd_class" = "read-only" ] && [ "$command_name" = "sprint-status" ]; then
    # sprint-status without --sprint: no default, no refuse — return empty
    return 0
  elif [ -n "$bound_id" ]; then
    target_id="$bound_id"
  else
    # Unbound: try single-sprint default
    local active_sprints=""
    active_sprints="$(_rsa_list_active_sprints "$state_dir")"
    local active_count=0
    if [ -n "$active_sprints" ]; then
      active_count="$(printf '%s\n' "$active_sprints" | wc -l | tr -d ' ')"
    fi

    if [ "$active_count" -eq 1 ]; then
      target_id="$(printf '%s' "$active_sprints" | head -1)"
    elif [ "$active_count" -eq 0 ]; then
      printf '%s: error: no active sprint found\n' "$_SB_SCRIPT_NAME" >&2
      return "$SPRINT_NOT_FOUND"
    else
      # Multiple active sprints, unbound, no --sprint: refuse
      printf '%s: error: specify --sprint {sprint_id}; active sprints:\n' "$_SB_SCRIPT_NAME" >&2
      printf '%s\n' "$active_sprints" >&2
      return "$SPRINT_AMBIGUOUS"
    fi
  fi

  # --- Closed-binding guard (exit 17) with exceptions (R43) ---
  if [ "$binding_closed" = true ]; then
    # Check per-command exceptions BEFORE the exit-17 refusal
    local exception_applies=false

    # Exception (a): action-items is sprint-optional (handled above, but
    # defensive in case this code path is reached via a class reclassification)
    if [ "$command_name" = "action-items" ]; then
      exception_applies=true
    fi

    # Exception (b): sprint-close on the bound closed sprint when archive missing
    if [ "$command_name" = "sprint-close" ] && [ "$target_id" = "$bound_id" ]; then
      local bc_archive=""
      bc_archive="$(_rsa_find_archive "$bound_id" "$state_dir")"
      if [ -z "$bc_archive" ]; then
        exception_applies=true  # resume path
      fi
    fi

    # Exception (c): sprint-review on the bound closed sprint (historical)
    if [ "$command_name" = "sprint-review" ] && [ "$target_id" = "$bound_id" ]; then
      exception_applies=true
    fi

    # Read-only class is unaffected by closed binding
    if [ "$cmd_class" = "read-only" ]; then
      exception_applies=true
    fi

    # sprint-close idempotent on the bound closed sprint with archive present
    if [ "$command_name" = "sprint-close" ] && [ "$target_id" = "$bound_id" ]; then
      local bc2_archive=""
      bc2_archive="$(_rsa_find_archive "$bound_id" "$state_dir")"
      if [ -n "$bc2_archive" ]; then
        exception_applies=true  # idempotent
      fi
    fi

    if [ "$exception_applies" = false ]; then
      printf '%s: error: bound sprint %s is closed; start a new session or close the sprint\n' \
        "$_SB_SCRIPT_NAME" "$bound_id" >&2
      return "$SPRINT_BOUND_CLOSED"
    fi
  fi

  # --- Run-sprint class: refuse different --sprint ---
  if [ "$cmd_class" = "run-sprint" ]; then
    if [ -n "$sprint_arg" ] && [ -n "$bound_id" ] && [ "$sprint_arg" != "$bound_id" ]; then
      printf '%s: error: already bound to %s\n' "$_SB_SCRIPT_NAME" "$bound_id" >&2
      return "$SPRINT_BOUND_MISMATCH"
    fi
  fi

  # --- Cross-sprint override log ---
  if [ -n "$sprint_arg" ] && [ -n "$bound_id" ] && [ "$sprint_arg" != "$bound_id" ]; then
    printf 'sprint override: bound=%s target=%s command=%s\n' \
      "$bound_id" "$sprint_arg" "$command_name" >&2
  fi

  # --- Validate the target sprint ID exists ---
  local target_status=""
  target_status="$(_sb_sprint_status "$target_id" "$state_dir")"

  if [ "$target_status" = "missing" ]; then
    # Check archive
    local t_archive=""
    t_archive="$(_rsa_find_archive "$target_id" "$state_dir")"
    if [ -z "$t_archive" ]; then
      printf '%s: error: sprint not found: %s\n' "$_SB_SCRIPT_NAME" "$target_id" >&2
      return "$SPRINT_NOT_FOUND"
    fi
    target_status="closed"  # archived sprints are treated as closed
  fi

  # --- Apply command class rules ---
  case "$cmd_class" in
    read-only)
      # Accept any state
      ;;
    mutating)
      if [ "$target_status" = "closed" ]; then
        # Per-command exceptions for closed sprints
        case "$command_name" in
          sprint-close)
            # Always return exit 0: close.sh handles idempotent/resume
            ;;
          sprint-review)
            # Historical read-only mode on closed sprints
            ;;
          *)
            printf '%s: error: sprint is closed: %s\n' "$_SB_SCRIPT_NAME" "$target_id" >&2
            return "$SPRINT_REFUSED_CLOSED"
            ;;
        esac
      fi
      ;;
    run-sprint)
      if [ "$target_status" = "closed" ]; then
        printf '%s: error: sprint is closed: %s\n' "$_SB_SCRIPT_NAME" "$target_id" >&2
        return "$SPRINT_REFUSED_CLOSED"
      fi
      ;;
  esac

  printf '%s' "$target_id"
  return 0
}

# ---------- CLI entry point ----------

# Direct invocation: session-binding.sh <subcmd> [args]
#   read  — print binding state
#   resolve — resolve_sprint_arg wrapper
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
    resolve)
      resolve_sprint_arg "$@"
      return $?
      ;;
    "")
      printf '%s: error: subcommand required (e.g. "read", "resolve")\n' "$_SB_SCRIPT_NAME" >&2
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
