#!/usr/bin/env bash
# bound-exec.sh — run a command with a wall-clock deadline.
#
# Starts the command in the background and launches a watchdog that kills
# it (and its children) when the deadline expires.  Stdout/stderr pass
# through; the caller sees the command's exit code on normal completion
# and 142 when the bound fires.
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
# Runs <command> in the background with a watchdog that kills the process
# tree after <seconds>.  Returns the command's exit code, or 142 if the
# bound fired.
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

  # Run the command in the background.  Stdout/stderr are inherited,
  # so output passes through to the caller.
  "$@" &
  local cmd_pid=$!

  # Watchdog: sleeps for the bound, then kills the command and its
  # direct children (handles the case where the command spawned a
  # subprocess, e.g. a shell script running an external binary).
  # Stdin/stdout/stderr are redirected to /dev/null so the watchdog's
  # sleep process does not hold the caller's file descriptors open
  # (which would cause bats `run` and pipe-based captures to hang).
  (
    "$_BE_REAL_SLEEP" "$bound" 2>/dev/null
    if kill -0 "$cmd_pid" 2>/dev/null; then
      touch "$_be_killed_flag"
      # Kill direct children first (so grandchildren don't orphan),
      # then the command itself.
      pkill -P "$cmd_pid" 2>/dev/null || true
      kill "$cmd_pid" 2>/dev/null || true
    fi
  ) </dev/null >/dev/null 2>&1 &
  local wd_pid=$!

  # Wait for the command to finish (or be killed)
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?

  # Clean up the watchdog: kill its children (the sleep) first to
  # avoid orphaned processes, then the subshell itself.
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
