#!/usr/bin/env bash
# ci-wait.sh — gaia-dev-story CI status polling (E28-S53)
#
# Polls CI check status for a PR with configurable timeout and 30-second
# cadence. Reports success, failure, or timeout with actionable messages.
#
# Usage:
#   ci-wait.sh <pr_number> [--timeout <minutes>]
#
# Environment:
#   PROJECT_PATH — required. The git working directory.
#
# Exit codes:
#   0 — all CI checks passed
#   1 — CI check failed or timeout exceeded

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/ci-wait.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# E53-S234 — Non-git CWD guard: skip-with-warning when CWD is outside any git
# work tree. CI polling is meaningless when there is no PR (there's no repo).
# shellcheck source=../../../scripts/lib/non-git-cwd-guard.sh
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$GUARD_DIR/../../../scripts/lib/non-git-cwd-guard.sh"
non_git_cwd_skip "$SCRIPT_NAME" || exit 0

if [ $# -lt 1 ]; then
  die "usage: ci-wait.sh <pr_number> [--timeout <minutes>]"
fi

PR_NUMBER="$1"
shift

TIMEOUT_MINUTES=15
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT_MINUTES="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

WORK_DIR="${PROJECT_PATH:-.}"
cd "$WORK_DIR" || die "cannot cd to $WORK_DIR"

if ! command -v gh >/dev/null 2>&1; then
  die "Required tool gh not found. Install it to poll CI status."
fi

TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60))
POLL_INTERVAL=30
ELAPSED=0
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5

log "waiting for CI checks on PR #${PR_NUMBER} (timeout: ${TIMEOUT_MINUTES}m)"

while true; do
  # Check timeout
  if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
    log "CI checks timed out after ${TIMEOUT_MINUTES} minutes."
    log "Resume with /gaia-resume after checks complete."
    exit 1
  fi

  # Poll checks
  checks_output=$(gh pr checks "$PR_NUMBER" --json name,status,conclusion 2>&1) || {
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
      die "CI polling failed ${MAX_CONSECUTIVE_FAILURES} consecutive times. Last error: $checks_output"
    fi
    log "transient polling error (attempt ${CONSECUTIVE_FAILURES}/${MAX_CONSECUTIVE_FAILURES}): $checks_output"
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    continue
  }

  CONSECUTIVE_FAILURES=0

  # Check if all checks have concluded
  pending=$(echo "$checks_output" | grep -c '"status":"IN_PROGRESS"\|"status":"QUEUED"\|"status":"PENDING"' 2>/dev/null || echo "0")
  failed=$(echo "$checks_output" | grep -c '"conclusion":"FAILURE"\|"conclusion":"CANCELLED"\|"conclusion":"TIMED_OUT"' 2>/dev/null || echo "0")

  if [ "$failed" -gt 0 ]; then
    log "CI check(s) failed. Fix the issue, push again, and resume with /gaia-resume."
    echo "$checks_output" >&2
    exit 1
  fi

  if [ "$pending" -eq 0 ]; then
    log "all CI checks passed (elapsed: ${ELAPSED}s)"
    echo "passed"
    exit 0
  fi

  log "CI checks in progress (${pending} pending, elapsed: ${ELAPSED}s)..."
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
