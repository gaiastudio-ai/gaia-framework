#!/usr/bin/env bash
# bound-exec.sh — run a command with a wall-clock deadline.
#
# Starts the command in its own process group and launches a watchdog
# that kills the entire group when the deadline expires.  Stdout/stderr
# pass through; the caller sees the command's exit code on normal
# completion and 142 when the bound fires.
#
# Usage (as library):
#   source bound-exec.sh
#   bound_exec <seconds> -- <command> [args...]
#
# Returns:
#   Command's exit code on normal completion.
#   142 — bound exceeded (command killed).
#   1   — usage error (no command, invalid bound).
#
# Process-group isolation:
#   The command runs in its own process group so the watchdog can kill
#   the entire descendant tree — not just direct children.  On Linux,
#   setsid(1) creates a new session (and thus a new group).  On macOS
#   (where setsid is absent), perl POSIX::setpgid(0,0) moves the child
#   into its own group without creating a new session.
#
# Works on macOS without timeout/gtimeout and under /bin/bash 3.2.
# No associative arrays, no mapfile, no ${x,,}.

set -euo pipefail
LC_ALL=C; export LC_ALL

_BE_SCRIPT_NAME="bound-exec.sh"
_be_log() { printf '%s: %s\n' "$_BE_SCRIPT_NAME" "$*" >&2; }

# Resolve the real sleep binary at source time so the watchdog is immune
# to PATH shims (e.g. test harnesses that replace sleep with a no-op).
_BE_REAL_SLEEP=""
for _be_p in /bin/sleep /usr/bin/sleep; do
  if [ -x "$_be_p" ]; then
    _BE_REAL_SLEEP="$_be_p"
    break
  fi
done
[ -z "$_BE_REAL_SLEEP" ] && _BE_REAL_SLEEP="sleep"

# bound_exec <seconds> -- <command> [args...]
# Runs <command> in its own process group with a watchdog that kills the
# entire group after <seconds>.  Returns the command's exit code, or 142
# if the bound fired.
bound_exec() {
  local bound="$1"; shift
  [ "${1:-}" = "--" ] && shift

  if [ $# -eq 0 ]; then
    _be_log "error: no command specified"
    return 1
  fi

  # Validate: must be a non-negative integer
  case "$bound" in
    ''|*[!0-9]*)
      _be_log "error: bound must be a non-negative integer, got '${bound}'"
      return 1
      ;;
  esac

  # Bound of 0 means no time — immediate expiry
  if [ "$bound" -eq 0 ]; then
    _be_log "bound exceeded (0s)"
    return 142
  fi

  # Flag file: set by the watchdog when it kills the command.  This
  # distinguishes a watchdog kill from any other SIGTERM the command
  # might receive.
  local _be_killed_flag
  _be_killed_flag="${TMPDIR:-/tmp}/bound-exec-$$-${RANDOM:-0}.flag"
  rm -f "$_be_killed_flag"

  # Run the command in its own process group so the watchdog can kill the
  # entire descendant tree.
  #
  # When this is the outermost bound_exec, create a new process group:
  #   Linux:  setsid(1) creates a new session (+ new process group).
  #   macOS:  perl POSIX::setpgid(0,0) creates a new group only.
  #   Fallback: run without group isolation (direct-child kill only).
  #
  # When nested (an inner bound_exec inside an outer one), skip group
  # creation so the inner command stays in the outer's group.  This
  # prevents the outer group kill from missing descendants that moved
  # to a nested group.
  #
  # Close fds above 2 before exec so test-harness capture pipes (bats
  # uses high fds) are not inherited by descendants.
  local _be_has_group=1
  local _be_nested="${_BE_IN_BOUND:-0}"
  if [ "$_be_nested" -eq 1 ]; then
    # Inner bound_exec: stay in the outer's process group.
    "$@" &
    _be_has_group=0
  elif command -v setsid >/dev/null 2>&1; then
    (
      # shellcheck disable=SC2030
      export _BE_IN_BOUND=1
      if [ -d /proc/self/fd ]; then
        for _be_fd in /proc/self/fd/*; do
          _be_fdn="${_be_fd##*/}"
          [ "$_be_fdn" -gt 2 ] 2>/dev/null && eval "exec ${_be_fdn}>&-" 2>/dev/null || true
        done
      else
        for _be_fdn in $(seq 3 63 2>/dev/null || echo "3 4 5 6 7 8 9"); do
          eval "exec ${_be_fdn}>&-" 2>/dev/null || true
        done
      fi
      exec setsid "$@"
    ) &
  elif command -v perl >/dev/null 2>&1; then
    (
      # shellcheck disable=SC2031
      export _BE_IN_BOUND=1
      if [ -d /proc/self/fd ]; then
        for _be_fd in /proc/self/fd/*; do
          _be_fdn="${_be_fd##*/}"
          [ "$_be_fdn" -gt 2 ] 2>/dev/null && eval "exec ${_be_fdn}>&-" 2>/dev/null || true
        done
      else
        for _be_fdn in $(seq 3 63 2>/dev/null || echo "3 4 5 6 7 8 9"); do
          eval "exec ${_be_fdn}>&-" 2>/dev/null || true
        done
      fi
      exec perl -e '
        use POSIX qw(setpgid);
        setpgid(0, 0) or warn "bound-exec: setpgid: $!\n";
        exec @ARGV or die "bound-exec: exec: $!\n";
      ' -- "$@"
    ) &
  else
    # Neither setsid nor perl — run without process-group isolation.
    "$@" &
    _be_has_group=0
  fi
  local cmd_pid=$!
  local cmd_pgid="$cmd_pid"

  # Watchdog: sleeps for the bound, then kills the command's process
  # group (TERM, 1 s grace, KILL) or falls back to direct-child kill
  # when group isolation is unavailable.
  #
  # Close ALL fds (including high fds from test harnesses like bats)
  # before sleeping so the watchdog's sleep cannot hold a pipe fd open.
  # Without this, an orphaned watchdog sleep keeps bats waiting.
  (
    if [ -d /proc/self/fd ]; then
      for _be_fd in /proc/self/fd/*; do
        _be_fdn="${_be_fd##*/}"
        [ "$_be_fdn" -gt 2 ] 2>/dev/null && eval "exec ${_be_fdn}>&-" 2>/dev/null || true
      done
    else
      for _be_fdn in $(seq 3 63 2>/dev/null || echo "3 4 5 6 7 8 9"); do
        eval "exec ${_be_fdn}>&-" 2>/dev/null || true
      done
    fi
    "$_BE_REAL_SLEEP" "$bound" 2>/dev/null
    if kill -0 "$cmd_pid" 2>/dev/null; then
      touch "$_be_killed_flag"
      if [ "$_be_has_group" -eq 1 ]; then
        kill -- -"$cmd_pgid" 2>/dev/null || true
        "$_BE_REAL_SLEEP" 1 2>/dev/null || true
        kill -9 -- -"$cmd_pgid" 2>/dev/null || true
      else
        pkill -P "$cmd_pid" 2>/dev/null || true
        kill "$cmd_pid" 2>/dev/null || true
      fi
    fi
  ) </dev/null >/dev/null 2>&1 &
  local wd_pid=$!

  # Wait for the command to finish (or be killed)
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?

  # Clean up the watchdog: kill its sleep first, then the subshell,
  # then reap both.
  pkill -P "$wd_pid" 2>/dev/null || true
  kill "$wd_pid" 2>/dev/null || true
  wait "$wd_pid" 2>/dev/null || true

  # Check if the watchdog killed the command
  if [ -f "$_be_killed_flag" ]; then
    rm -f "$_be_killed_flag"
    _be_log "bound exceeded (${bound}s)"
    return 142
  fi
  rm -f "$_be_killed_flag"
  return "$rc"
}

# When invoked as a script (not sourced), parse -- and run.
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${BASH_SOURCE[0]:-}" = "" ]; then
  if [ $# -lt 2 ]; then
    _be_log "usage: bound-exec.sh <seconds> -- <command> [args...]"
    exit 1
  fi
  bound_exec "$@"
fi
