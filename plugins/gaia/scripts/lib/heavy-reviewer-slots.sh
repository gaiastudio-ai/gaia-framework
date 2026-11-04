#!/usr/bin/env bash
# heavy-reviewer-slots.sh — counting semaphore for heavy reviewers.
#
# Caps the number of concurrently running heavy reviewers (those that
# spawn test suites, mutation runs, or property-test subprocesses)
# system-wide. Prevents parallel reviews from overloading the machine.
#
# Public API (CLI):
#   heavy-reviewer-slots.sh run [--limit N] [--wait-secs S] -- <command> [args...]
#
# Public API (library, when sourced):
#   heavy_reviewer_acquire [--limit N] [--wait-secs S]
#   heavy_reviewer_release
#   heavy_reviewer_run [--limit N] [--wait-secs S] -- <command> [args...]
#
# Slot directory: ${GAIA_STATE_DIR}/review-semaphore.d/
# Mutex:          ${GAIA_STATE_DIR}/review-semaphore.lock
# Each slot file: contains "<PID> <epoch>\n"
#
# Default limit: 4 (from config review.max_concurrent_heavy_reviewers,
#   resolved at point of use).
# Default wait bound: 600s (overridable via GAIA_REVIEW_SEMAPHORE_WAIT_SECS).
#
# On wait expiry: proceeds without a slot and logs a warning (fail open).
# On exit/failure/SIGINT: releases slot via trap.
#
# POSIX discipline: bash 3.2 (macOS), no associative arrays, no mapfile.

set -euo pipefail
LC_ALL=C; export LC_ALL

_HRS_SCRIPT_NAME="heavy-reviewer-slots.sh"
_HRS_SLOT_DIR=""
_HRS_LOCK_PATH=""
_HRS_MY_SLOT=""
_HRS_FD=42
_HRS_ACQUIRED=0

# --- Resolve paths through the shared paths helper ---

_hrs_resolve_paths() {
  if [ -n "$_HRS_SLOT_DIR" ]; then
    return 0
  fi

  local state_dir="${GAIA_STATE_DIR:-}"
  if [ -z "$state_dir" ]; then
    # Try to source the paths helper.
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    if [ -f "${script_dir}/gaia-paths.sh" ]; then
      # shellcheck source=gaia-paths.sh
      source "${script_dir}/gaia-paths.sh" 2>/dev/null || true
      state_dir="${GAIA_STATE_DIR:-}"
    fi
  fi

  if [ -z "$state_dir" ]; then
    printf '%s: cannot resolve state directory (GAIA_STATE_DIR unset and paths helper unavailable)\n' \
      "$_HRS_SCRIPT_NAME" >&2
    return 1
  fi

  _HRS_SLOT_DIR="${state_dir}/review-semaphore.d"
  _HRS_LOCK_PATH="${state_dir}/review-semaphore.lock"
}

# --- Resolve the configured limit ---

_hrs_resolve_limit() {
  local limit="${1:-}"
  if [ -n "$limit" ]; then
    printf '%s' "$limit"
    return 0
  fi

  # Try resolve-config.sh for the configured value.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  local resolve_config="${script_dir}/../resolve-config.sh"
  if [ -x "$resolve_config" ]; then
    local configured
    configured="$(bash "$resolve_config" --field review.max_concurrent_heavy_reviewers 2>/dev/null)" || configured=""
    if [ -n "$configured" ] && [ "$configured" -ge 1 ] 2>/dev/null; then
      printf '%s' "$configured"
      return 0
    fi
  fi

  # Default: 4
  printf '4'
}

# --- Source the locking helper ---

_hrs_source_lock() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  if [ -f "${script_dir}/acquire-lock.sh" ]; then
    # shellcheck source=acquire-lock.sh
    source "${script_dir}/acquire-lock.sh"
    return 0
  fi
  printf '%s: acquire-lock.sh not found\n' "$_HRS_SCRIPT_NAME" >&2
  return 1
}

# --- Count live slots (must be called under mutex) ---

_hrs_count_live_slots() {
  local count=0
  local f pid
  for f in "${_HRS_SLOT_DIR}"/slot-*; do
    [ -f "$f" ] || continue
    read -r pid _ < "$f" 2>/dev/null || continue
    if [ -z "$pid" ] || ! [ "$pid" -gt 0 ] 2>/dev/null; then
      # Invalid slot file — reclaim.
      rm -f "$f" 2>/dev/null || true
      continue
    fi
    if kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
    else
      # Dead holder — reclaim.
      printf '%s: reclaimed stale slot %s (pid %s dead)\n' \
        "$_HRS_SCRIPT_NAME" "$(basename "$f")" "$pid" >&2
      rm -f "$f" 2>/dev/null || true
    fi
  done
  printf '%s' "$count"
}

# --- Create a slot file (must be called under mutex) ---

# --- Create a slot file (must be called under mutex) ---
# Uses BASHPID when available (bash 4+) for unique per-subshell naming;
# falls back to $$ + $RANDOM for bash 3.2 where subshells share $$.

_hrs_create_slot() {
  local my_pid="${BASHPID:-$$}"
  local slot_file="${_HRS_SLOT_DIR}/slot-${my_pid}.${RANDOM}"
  printf '%s %s\n' "$my_pid" "$(date +%s)" > "$slot_file"
  _HRS_MY_SLOT="$slot_file"
}

# --- Public: heavy_reviewer_acquire ---

heavy_reviewer_acquire() {
  local limit=""
  local wait_secs="${GAIA_REVIEW_SEMAPHORE_WAIT_SECS:-600}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --wait-secs) wait_secs="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _hrs_resolve_paths || return 1
  _hrs_source_lock || return 1
  limit="$(_hrs_resolve_limit "$limit")"
  mkdir -p "$_HRS_SLOT_DIR" 2>/dev/null || true

  local start_epoch elapsed
  start_epoch="$(date +%s)"

  while true; do
    # Acquire the mutex for the count-and-claim step.
    if ! acquire_lock "$_HRS_LOCK_PATH" 10 "$_HRS_FD"; then
      printf '%s: warning: could not acquire semaphore mutex; proceeding without slot\n' \
        "$_HRS_SCRIPT_NAME" >&2
      _HRS_ACQUIRED=0
      return 0
    fi

    local live_count
    live_count="$(_hrs_count_live_slots)"

    if [ "$live_count" -lt "$limit" ]; then
      _hrs_create_slot
      release_lock "$_HRS_FD"
      _HRS_ACQUIRED=1
      return 0
    fi

    release_lock "$_HRS_FD"

    # Check wait bound.
    elapsed=$(( $(date +%s) - start_epoch ))
    if [ "$elapsed" -ge "$wait_secs" ]; then
      printf '%s: warning: wait bound %ss expired (%s/%s slots in use); proceeding without slot\n' \
        "$_HRS_SCRIPT_NAME" "$wait_secs" "$live_count" "$limit" >&2
      _HRS_ACQUIRED=0
      return 0
    fi

    # Bounded retry with jitter (150-350ms).
    local jitter=$(( RANDOM % 200 + 150 ))
    sleep "$(printf '%d.%03d' $((jitter / 1000)) $((jitter % 1000)))" 2>/dev/null \
      || sleep 1
  done
}

# --- Public: heavy_reviewer_release ---

heavy_reviewer_release() {
  if [ "$_HRS_ACQUIRED" = "1" ] && [ -n "$_HRS_MY_SLOT" ]; then
    rm -f "$_HRS_MY_SLOT" 2>/dev/null || true
    _HRS_ACQUIRED=0
    _HRS_MY_SLOT=""
  fi
}

# --- Public: heavy_reviewer_run ---

heavy_reviewer_run() {
  local limit=""
  local wait_secs="${GAIA_REVIEW_SEMAPHORE_WAIT_SECS:-600}"
  local cmd_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --wait-secs) wait_secs="$2"; shift 2 ;;
      --) shift; cmd_args=("$@"); break ;;
      *) shift ;;
    esac
  done

  if [ ${#cmd_args[@]} -eq 0 ]; then
    printf '%s: run requires -- <command> [args...]\n' "$_HRS_SCRIPT_NAME" >&2
    return 1
  fi

  # Build acquire args.
  local acquire_args=()
  [ -n "$limit" ] && acquire_args+=(--limit "$limit")
  [ -n "$wait_secs" ] && acquire_args+=(--wait-secs "$wait_secs")

  heavy_reviewer_acquire "${acquire_args[@]+"${acquire_args[@]}"}"

  # Release on exit, failure, or signal.
  trap 'heavy_reviewer_release' EXIT INT TERM HUP

  local rc=0
  "${cmd_args[@]}" || rc=$?

  heavy_reviewer_release
  trap - EXIT INT TERM HUP

  return "$rc"
}

# --- CLI entry point (only when executed directly, not sourced) ---

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    run)
      shift
      heavy_reviewer_run "$@"
      exit $?
      ;;
    --help|-h)
      cat <<'EOF'
heavy-reviewer-slots.sh — counting semaphore for heavy reviewers.

Usage:
  heavy-reviewer-slots.sh run [--limit N] [--wait-secs S] -- <command> [args...]

Options:
  --limit N       Override the max concurrent heavy reviewers (default: from config or 4).
  --wait-secs S   Override the wait bound in seconds (default: 600 or GAIA_REVIEW_SEMAPHORE_WAIT_SECS).

Environment:
  GAIA_REVIEW_SEMAPHORE_WAIT_SECS   Override the default wait bound.
  GAIA_STATE_DIR                    State directory (resolved via gaia-paths.sh if unset).
EOF
      exit 0
      ;;
    *)
      printf '%s: unknown subcommand: %s (use "run" or "--help")\n' \
        "$_HRS_SCRIPT_NAME" "${1:-}" >&2
      exit 1
      ;;
  esac
fi
