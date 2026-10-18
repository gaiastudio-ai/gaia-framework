#!/usr/bin/env bash
# bind.sh — sprint binding at /gaia-run-sprint activation.
#
# Called at sprint-run start to bind the session to a sprint.
# In concurrent mode:
#   - With --sprint <id>: binds to the specified sprint.
#   - Without --sprint: auto-binds (0 active = no binding, 1 = auto-bind,
#     N = refuse with listing).
# In single-sprint mode: no binding occurs.
#
# Exit codes:
#   0 — binding succeeded (or skipped in single-sprint mode)
#   1 — validation or auto-bind failure
#   2 — already bound to a different sprint

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="${0##*/}"

# Resolve plugin root from this script's location.
BIND_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${BIND_SCRIPT_DIR}/../../.."

# Source the session-binding library.
# shellcheck source=../../../scripts/lib/session-binding.sh
source "${PLUGIN_ROOT}/scripts/lib/session-binding.sh"

# ---------- Concurrent-mode detection ----------

# Read max_concurrent_active from project config.
_bind_read_max_concurrent() {
  local cfg="${PROJECT_CONFIG:-}"
  if [ -z "$cfg" ]; then
    if [ -n "${PROJECT_ROOT:-}" ]; then
      cfg="${PROJECT_ROOT%/}/.gaia/config/project-config.yaml"
    fi
  fi
  local val=""
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    if /usr/bin/grep -q 'max_concurrent_active' "$cfg" 2>/dev/null; then
      if command -v yq >/dev/null 2>&1; then
        val="$(yq '.sprint.max_concurrent_active' "$cfg" 2>/dev/null)" || val=""
      fi
    fi
  fi
  case "$val" in
    ''|null|*[!0-9]*) val="1" ;;
  esac
  printf '%s' "$val"
}

# Check for per-sprint state files.
_bind_per_sprint_files_exist() {
  local state_dir="$1"
  [ -d "$state_dir" ] || return 1
  local found=""
  found="$(find "$state_dir" -maxdepth 1 -name 'sprint-status-*.yaml' ! -name '*.lock' ! -name '*.result' 2>/dev/null | head -1)" || found=""
  [ -n "$found" ]
}

_bind_is_concurrent_mode() {
  local max
  max="$(_bind_read_max_concurrent)"
  if [ "$max" -gt 1 ] 2>/dev/null; then
    return 0
  fi
  local state_dir="${PROJECT_ROOT:-.}/.gaia/state"
  if _bind_per_sprint_files_exist "$state_dir"; then
    return 0
  fi
  return 1
}

# ---------- Active sprint enumeration ----------

# List active sprint IDs from per-sprint state files.
_bind_list_active_sprints() {
  local state_dir="${PROJECT_ROOT:-.}/.gaia/state"
  local active_ids=""
  local count=0

  if [ ! -d "$state_dir" ]; then
    printf '0'
    return 0
  fi

  local f="" sid="" status=""
  for f in "${state_dir}"/sprint-status-*.yaml; do
    [ -f "$f" ] || continue
    # Skip lock and result files.
    case "$f" in *.lock|*.result) continue ;; esac

    sid="$(yq '.sprint_id' "$f" 2>/dev/null)" || continue
    status="$(yq '.status' "$f" 2>/dev/null)" || continue
    [ -n "$sid" ] && [ "$sid" != "null" ] || continue

    if [ "$status" = "active" ]; then
      if [ $count -gt 0 ]; then
        active_ids="${active_ids} ${sid}"
      else
        active_ids="$sid"
      fi
      count=$((count + 1))
    fi
  done

  printf '%d %s' "$count" "$active_ids"
}

# ---------- Main binding logic ----------

# bind_sprint — bind the session to a sprint.
#
# Arguments:
#   --sprint <id>   (optional) explicit sprint ID
#
# Prints the bound sprint ID on stdout.
bind_sprint() {
  local sprint_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sprint) shift; sprint_arg="${1:-}"; shift || true ;;
      *) shift ;;
    esac
  done

  local state_dir="${PROJECT_ROOT:-.}/.gaia/state"

  # Single-sprint mode: skip binding entirely.
  if ! _bind_is_concurrent_mode; then
    return 0
  fi

  # Provision the binding directory.
  provision_binding_dir || return $?

  # Check for existing binding (re-entry or conflict).
  local binding_file="${GAIA_BINDING_DIR}/${_SB_BINDING_FILENAME}"
  if [ -f "$binding_file" ]; then
    local existing=""
    existing="$(cat "$binding_file" 2>/dev/null | tr -d '\n')" || existing=""

    if [ -n "$sprint_arg" ] && [ -n "$existing" ] && [ "$sprint_arg" != "$existing" ]; then
      printf '%s: error: already bound to %s\n' "$SCRIPT_NAME" "$existing" >&2
      return 2
    fi

    # Re-entry: same sprint or no --sprint.
    if [ -n "$existing" ]; then
      printf '%s' "$existing"
      return 0
    fi
  fi

  if [ -n "$sprint_arg" ]; then
    # Explicit --sprint: bind to the specified sprint.
    write_binding "$sprint_arg" "$state_dir" || return $?
    printf '%s' "$sprint_arg"
    return 0
  fi

  # Auto-bind logic: count active sprints.
  local active_info=""
  active_info="$(_bind_list_active_sprints)"
  local count="${active_info%% *}"
  local ids="${active_info#* }"

  case "$count" in
    0)
      # Zero active sprints: no binding. Existing behavior preserved.
      return 0
      ;;
    1)
      # One active sprint: auto-bind.
      local single_id="${ids%% *}"
      write_binding "$single_id" "$state_dir" || return $?
      printf '%s' "$single_id"
      return 0
      ;;
    *)
      # Multiple active sprints: refuse with listing.
      printf '%s: error: multiple active sprints; specify --sprint {sprint_id}\n' "$SCRIPT_NAME" >&2
      printf '%s: active sprints: %s\n' "$SCRIPT_NAME" "$ids" >&2
      return 1
      ;;
  esac
}

# Direct invocation entry point.
if [ "${BASH_SOURCE[0]}" = "$0" ] 2>/dev/null || [ "${0##*/}" = "bind.sh" ]; then
  bind_sprint "$@"
fi
