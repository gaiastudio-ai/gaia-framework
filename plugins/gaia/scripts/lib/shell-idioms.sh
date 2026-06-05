#!/usr/bin/env bash
# shell-idioms.sh — reusable shell helpers for GAIA scripts.
#
# This file is intended to be SOURCED, not executed:
#
#   source "$(dirname "$0")/../../../scripts/lib/shell-idioms.sh"
#
# Companion docs in skills/gaia-shell-idioms/SKILL.md.
#
# All helpers are written for POSIX-compatible bash (3.2+ for macOS) and
# avoid GNU-only options.

# safe_grep_log — SIGPIPE-safe `git log | grep` replacement.
#
# Background:
#   `git log | grep -q PATTERN` combined with `set -euo pipefail` is unsafe.
#   When grep matches early it closes the pipe; git log then receives SIGPIPE
#   and exits 141. With `pipefail` set, the pipeline's overall status becomes
#   141 even though the user-visible outcome was "match found", and `set -e`
#   aborts the caller. The recurring workaround is to capture git log output
#   into a variable first, then grep the variable. This helper centralises
#   that workaround so every caller doesn't reinvent it.
#
# Usage:
#   safe_grep_log [grep_flags...] <pattern> [git_log_args...]
#
#   Any leading args starting with `-` are forwarded to grep (e.g. -i, -E,
#   -q). The first non-flag arg is the grep pattern. Remaining args are
#   forwarded to `git log` (e.g. --oneline, a branch name, --format='%B').
#
# Output:
#   Lines from `git log <git_log_args>` matching <pattern> are printed on
#   stdout, one per line.
#
# Exit codes:
#   0 — at least one matching line was found
#   1 — no matching lines (clean no-match; not an error)
#   2 — usage error (missing pattern)
#
# Examples:
#   # Was: git log --oneline main | grep -iqE "\bSTORY-KEY\b"   (SIGPIPE-prone)
#   # Now: safe_grep_log -i -E "\bSTORY-KEY\b" --oneline main
#
#   # Match against full commit bodies:
#   safe_grep_log -i -E "Story:[[:space:]]*STORY-KEY" --format='%B' main
#
# Implementation note: we run `git log` inside a command substitution so its
# stdout is captured fully BEFORE grep ever runs. That means grep can never
# close the pipe early on git, so SIGPIPE is impossible by construction.
# `|| true` on the capture line guards against `set -e` aborting on a git
# error (e.g. unknown branch); the empty capture then yields the expected
# exit-1 no-match.
safe_grep_log() {
  local grep_flags=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      -*) grep_flags+=("$1"); shift ;;
      *)  break ;;
    esac
  done

  if [ $# -lt 1 ]; then
    printf 'safe_grep_log: missing required <pattern> argument\n' >&2
    return 2
  fi

  local pattern="$1"; shift
  # Remaining args go to git log. May be empty.

  local log_output
  log_output="$(git log "$@" 2>/dev/null)" || true

  # Pipe the captured variable into grep. Even though the producer is now
  # `printf` on a fully-realised string (not a long-lived git process),
  # SIGPIPE CAN still fire under `set -o pipefail`: when the caller passes
  # `-q` to grep, grep exits immediately on first match; if the captured
  # string is large (e.g., the multi-thousand-commit history of a long-lived
  # `staging` branch), `printf` is still streaming bytes into the pipe and
  # receives SIGPIPE on next write. Under pipefail the pipeline's exit
  # status becomes 141 (printf's signal exit code), even though grep's
  # actual exit was 0 (match).
  #
  # The original implementation used `|| rc=$?` which captured pipeline
  # status — propagating the false 141 as a false-negative no-match. This
  # surfaced across several stories and most recently broke /gaia-dev-story
  # Step 14.
  #
  # Fix: capture grep's exit code via `${PIPESTATUS[1]}` directly,
  # NOT via `|| rc=$?` on the pipeline. PIPESTATUS surfaces each pipeline
  # stage's actual exit code regardless of pipefail. Combined with `|| true`
  # so that `set -e` doesn't abort the function on grep's expected exit-1
  # (clean no-match), this gives us the helper's documented 0/1 contract
  # under all pipefail/SIGPIPE combinations. The helper's documented
  # contract (matching lines emitted on stdout) is preserved — grep's
  # stdout is unredirected; only its exit code is re-routed via PIPESTATUS.
  #
  # ${arr[@]+"${arr[@]}"} guards against the bash-3.2 + set -u "unbound
  # variable" trap on empty-array expansion. macOS still ships bash 3.2.
  #
  # Two subtleties:
  #   1. PIPESTATUS is only valid IMMEDIATELY after the pipeline — any
  #      intervening command (including `|| true`) resets it. So we capture
  #      it into a local array on the very next line, then process.
  #   2. To survive `set -e` on grep's expected exit-1 (clean no-match), we
  #      temporarily disable errexit around the pipeline with `set +e` then
  #      restore it. This is more reliable than `|| true` (which would still
  #      reset PIPESTATUS) and works regardless of whether the caller had
  #      errexit set or not.
  local _pipestatus
  set +e
  printf '%s\n' "$log_output" | grep ${grep_flags[@]+"${grep_flags[@]}"} -- "$pattern"
  _pipestatus=("${PIPESTATUS[@]}")
  set -e
  # _pipestatus[1] is grep's exit code: 0 = match, 1 = no match. printf
  # may have been SIGPIPE'd (_pipestatus[0] == 141) when grep -q matched
  # and closed the pipe early — that is harmless and intentionally ignored.
  return "${_pipestatus[1]}"
}
