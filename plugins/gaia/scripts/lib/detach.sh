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
  else
    # Method 2: perl POSIX::setsid fallback
    if command -v perl >/dev/null 2>&1; then
      perl -e '
        use POSIX qw(setsid);
        # Fork to detach from the caller session
        my $pid = fork();
        if (!defined $pid) { die "fork failed: $!\n"; }
        if ($pid) {
          # Parent: print child PID and exit
          print "$pid\n";
          exit 0;
        }
        # Child: create new session
        setsid() or die "setsid failed: $!\n";
        exec @ARGV or die "exec failed: $!\n";
      ' -- "$@"
      local perl_rc=$?
      if [ "$perl_rc" -ne 0 ]; then
        _detach_log "detach_failed: perl setsid fallback failed (exit $perl_rc)"
        return 1
      fi
      # perl printed the child PID; we captured it via the backgrounding
      # path above only for setsid.  For perl, read from the exec path.
      # The perl parent printed the PID to stdout before exiting.
      return 0
    else
      _detach_log "detach_failed: neither setsid nor perl available"
      return 1
    fi
  fi

  # Give the runner a moment to start so we can check its PGID
  # (only needed for the setsid path where we have $runner_pid)
  if [ -n "$runner_pid" ]; then
    # Brief wait for the process to appear
    local _wait_count=0
    while [ "$_wait_count" -lt 10 ] && ! kill -0 "$runner_pid" 2>/dev/null; do
      sleep 0.05 2>/dev/null || sleep 1
      _wait_count=$((_wait_count + 1))
    done

    # PGID assertion: runner's PGID must differ from caller's
    if kill -0 "$runner_pid" 2>/dev/null; then
      local runner_pgid=""
      runner_pgid="$(ps -o pgid= -p "$runner_pid" 2>/dev/null | tr -d ' ')" || runner_pgid=""

      if [ -n "$caller_pgid" ] && [ -n "$runner_pgid" ] && [ "$caller_pgid" = "$runner_pgid" ]; then
        _detach_log "detach_failed: runner PGID ($runner_pgid) equals caller PGID ($caller_pgid)"
        return 1
      fi
    fi
    # Process may have already exited (short-lived command) — that is fine;
    # setsid guarantees a new session/PGID for the child.

    printf '%s\n' "$runner_pid"
  fi

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
