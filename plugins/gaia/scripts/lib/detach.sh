#!/usr/bin/env bash
# detach.sh — start a command in a new process group.
#
# Uses setsid (preferred) or perl POSIX::setsid (fallback) to ensure the
# runner's PGID differs from the caller's.  After launch, asserts the
# process-group split; refuses with detach_failed if neither method works.
#
# Usage:
#   detach.sh -- <command> [args...]
#   source detach.sh   # then call  detach_run <command> [args...]
#
# Exit codes:
#   0 — runner launched, PGID assertion passed
#   1 — detach_failed (no setsid, no perl fallback, or PGID assertion failed)
#
# Bash 3.2 compatible.  No associative arrays, no mapfile, no ${x,,}.

set -euo pipefail
LC_ALL=C; export LC_ALL

_DETACH_SCRIPT_NAME="detach.sh"

_detach_log() { printf '%s: %s\n' "$_DETACH_SCRIPT_NAME" "$*" >&2; }

# detach_run <command> [args...]
# Starts <command> in a new process group.  On success, prints the runner
# PID to stdout and returns 0.  On failure, prints detach_failed to stderr
# and returns 1.
detach_run() {
  if [ $# -eq 0 ]; then
    _detach_log "detach_failed: no command specified"
    return 1
  fi

  local caller_pgid=""
  # ps -o pgid= works on both macOS and Linux
  caller_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" || caller_pgid=""

  local runner_pid=""

  # Method 1: setsid (GNU coreutils / Linux default)
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
    runner_pid=$!
  elif command -v perl >/dev/null 2>&1; then
    # Method 2: perl POSIX::setsid fallback
    runner_pid="$(perl -e '
      use POSIX qw(setsid);
      my $pid = fork();
      if (!defined $pid) { die "fork failed: $!\n"; }
      if ($pid) {
        print "$pid\n";
        exit 0;
      }
      setsid() or die "setsid failed: $!\n";
      exec @ARGV or die "exec failed: $!\n";
    ' -- "$@")" || true
    if [ -z "$runner_pid" ]; then
      _detach_log "detach_failed: perl setsid fallback failed"
      return 1
    fi
  else
    _detach_log "detach_failed: neither setsid nor perl available"
    return 1
  fi

  # PGID assertion (both setsid and perl paths): poll until the runner's
  # PGID differs from the caller's, or the runner exits, or a 2-second
  # bound expires.  On Linux, `setsid "$@" &` can briefly leave the
  # child with the caller's PGID until setsid() executes; a single
  # read would race with that window.
  local _pgid_ok=0
  local _pgid_polls=0
  local _pgid_limit=40  # 40 * 0.05s = 2s bound
  while [ "$_pgid_polls" -lt "$_pgid_limit" ]; do
    if ! kill -0 "$runner_pid" 2>/dev/null; then
      # Runner exited — setsid guarantees a new session for the child
      _pgid_ok=1
      break
    fi
    local runner_pgid=""
    runner_pgid="$(ps -o pgid= -p "$runner_pid" 2>/dev/null | tr -d ' ')" || runner_pgid=""
    if [ -n "$runner_pgid" ] && [ -n "$caller_pgid" ] && [ "$runner_pgid" != "$caller_pgid" ]; then
      _pgid_ok=1
      break
    fi
    sleep 0.05 2>/dev/null || sleep 1
    _pgid_polls=$((_pgid_polls + 1))
  done

  if [ "$_pgid_ok" -eq 0 ] && kill -0 "$runner_pid" 2>/dev/null; then
    _detach_log "detach_failed: runner PGID still equals caller PGID after ${_pgid_limit} polls"
    return 1
  fi

  printf '%s\n' "$runner_pid"
  return 0
}

# When invoked as a script (not sourced), parse -- and run.
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${BASH_SOURCE[0]:-}" = "" ]; then
  # Strip leading -- if present
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  if [ $# -eq 0 ]; then
    _detach_log "detach_failed: usage: detach.sh -- <command> [args...]"
    exit 1
  fi
  detach_run "$@"
fi
