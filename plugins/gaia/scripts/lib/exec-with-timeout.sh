#!/usr/bin/env bash
# exec-with-timeout.sh — shared timeout-with-process-group-kill helper
#
# Provides `exec_with_timeout()` — runs a command with a hard timeout and a
# process-group-scoped kill so orphan grandchildren cannot survive.
#
# Three-tier cascade (macOS-first POSIX 3.2 compatible):
#   1. GNU `timeout` (Linux + Homebrew coreutils Linux-style)
#   2. `gtimeout` (Homebrew coreutils on macOS)
#   3. `perl -e 'alarm(...); exec(...)'` pure-POSIX fallback
#
# All tiers wrap the command under `setsid` to create a fresh process group;
# tier-1/tier-2 use `--kill-after` so the kill propagates to grandchildren via
# the process-group leader; tier-3 sends SIGKILL on alarm to the negative PID
# (process-group kill).
#
# Precedent: gaia-framework/plugins/gaia/scripts/run-tests.sh lines 257-291 ships
# a two-tier cascade without the process-group kill addition. This helper adds
# tier-2 (gtimeout) + setsid + process-group kill semantics.
#
# Usage:
#   source scripts/lib/exec-with-timeout.sh
#   exec_with_timeout <timeout-seconds> <command> [args...]
#
# Exit code:
#   - literal child exit code on normal termination
#   - 124 (GNU timeout) or 137 (SIGKILL) on timeout
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.

# _gaia_pg_wrap — internal helper. Wraps a command under `setsid` when
# available (Linux) so a fresh process group exists. Falls back to a plain
# invocation on macOS where `setsid` is absent (the timeout cascade then
# handles process-group kill via its `--kill-after` SIGKILL and the perl
# fallback uses POSIX::setpgid before exec).
_gaia_pg_wrap() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@"
  else
    "$@"
  fi
}

exec_with_timeout() {
  local timeout_s="$1"; shift
  if [ -z "$timeout_s" ] || [ $# -eq 0 ]; then
    printf 'exec_with_timeout: usage: exec_with_timeout <timeout-seconds> <command> [args...]\n' >&2
    return 2
  fi

  if command -v timeout >/dev/null 2>&1; then
    # GNU timeout. --kill-after gives the killed process N seconds before SIGKILL.
    _gaia_pg_wrap timeout --kill-after=2 "$timeout_s" "$@"
    return $?
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    # macOS Homebrew coreutils.
    _gaia_pg_wrap gtimeout --kill-after=2 "$timeout_s" "$@"
    return $?
  fi

  # Tier 3: perl alarm fallback. Pure POSIX. The perl process calls
  # POSIX::setpgid to create a new process group, then SIGKILLs the entire
  # group (negative PID idiom) on alarm.
  _gaia_pg_wrap perl -e '
    use POSIX qw(:sys_wait_h setpgid);
    my $timeout = shift;
    my $pid = fork();
    if ($pid == 0) {
      POSIX::setpgid(0, 0);
      exec(@ARGV);
      exit 127;
    }
    POSIX::setpgid($pid, $pid);
    local $SIG{ALRM} = sub {
      # SIGKILL to the negative pid = whole process group.
      kill("KILL", -$pid);
      exit 137;
    };
    alarm($timeout);
    waitpid($pid, 0);
    my $rc = $? >> 8;
    alarm(0);
    exit $rc;
  ' "$timeout_s" "$@"
}
