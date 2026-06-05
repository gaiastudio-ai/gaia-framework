#!/usr/bin/env bash
# git-push.sh — shared push helper for V2 GAIA dev/automation skills.
#
# Purpose:
#   Push the current branch to `origin` with a single retry on transient
#   network errors. Fails LOUDLY (non-zero exit) on auth / permission /
#   protected-branch errors — never silent.
#
# Usage:
#   git-push.sh [<remote>]
#
# Arguments:
#   <remote> — optional. The remote to push to. Defaults to "origin".
#
# Environment:
#   GAIA_GIT_PUSH_BACKOFF — optional. Seconds to sleep between the first
#                            and second push attempt on a network retry.
#                            Default 5. Tests set this to 0 for speed.
#
# Behavior:
#   1. Refuse to push if HEAD is on a protected branch (main / staging).
#      Delegates to lib/dev-story-security-invariants.sh::assert_branch_not_protected
#      when available; falls back to an inline check otherwise.
#   2. Run `git push -u <remote> <current-branch>`.
#      - Exit 0 on success.
#      - On non-zero exit, inspect captured stderr:
#          * Network indicators ("Could not resolve host", "Operation timed out",
#            "Connection refused", "Network is unreachable", "TLS handshake")
#            -> sleep $GAIA_GIT_PUSH_BACKOFF then retry ONCE.
#          * Anything else (auth, perm, ref-mismatch) -> exit non-zero
#            immediately. Auth errors MUST NOT trigger the network retry.
#
# Exit codes:
#   0 — push succeeded
#   1 — push failed (auth, perm, protected branch, two consecutive net errors)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia/git-push.sh"
log()  { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { log "$*"; exit "${2:-1}"; }

REMOTE="${1:-origin}"
BACKOFF="${GAIA_GIT_PUSH_BACKOFF:-5}"

# Resolve the security-invariants library if present.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVARIANTS_LIB="$SCRIPT_DIR/lib/dev-story-security-invariants.sh"

# Non-git CWD guard: skip-with-warning when CWD is outside any git
# work tree, so /gaia-dev-story steps degrade gracefully instead of HALT.
# shellcheck source=lib/non-git-cwd-guard.sh
. "$SCRIPT_DIR/lib/non-git-cwd-guard.sh"
non_git_cwd_skip "$SCRIPT_NAME" || exit 0

# ---------- 1. Protected-branch refusal ----------
_branch_check_inline() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [ -z "$branch" ]; then
    log "cannot determine current branch"
    return 1
  fi
  case "$branch" in
    main|staging)
      log "refuse to push from protected branch '$branch' — feature branches only"
      return 1
      ;;
  esac
  return 0
}

if [ -f "$INVARIANTS_LIB" ]; then
  # shellcheck disable=SC1090
  if ! ( source "$INVARIANTS_LIB" && assert_branch_not_protected ) 2>&1; then
    # The library writes its own descriptive message. Re-emit the current
    # branch in our own log line so users grep'ing for `git-push.sh` find it.
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
    log "refuse to push from protected branch '$branch'"
    exit 1
  fi
else
  _branch_check_inline || exit 1
fi

# ---------- 2. Push with single network-retry ----------
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$BRANCH" ] || die "cannot determine current branch"

# Network error indicator regex. Extended grep, anchored loosely.
NET_PATTERN='Could not resolve host|Operation timed out|Connection refused|Network is unreachable|TLS handshake|Couldn'\''t connect|temporarily unavailable'

_attempt_push() {
  local stderr_file rc
  stderr_file="$(mktemp)"
  set +e
  git push -u "$REMOTE" "$BRANCH" 2> "$stderr_file"
  rc=$?
  set -e
  cat "$stderr_file" >&2
  printf '%s\n' "$(cat "$stderr_file")"
  rm -f "$stderr_file"
  return "$rc"
}

# First attempt. We capture the stderr text via a roundabout, since
# function return semantics + bash subshells make piping tricky.
ATTEMPT_OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$ATTEMPT_OUTPUT_FILE"' EXIT

set +e
git push -u "$REMOTE" "$BRANCH" 2> "$ATTEMPT_OUTPUT_FILE"
rc=$?
set -e
cat "$ATTEMPT_OUTPUT_FILE" >&2

if [ "$rc" -eq 0 ]; then
  log "pushed $BRANCH -> $REMOTE"
  exit 0
fi

# Failure — classify the error.
err_text="$(cat "$ATTEMPT_OUTPUT_FILE" || true)"
if printf '%s' "$err_text" | grep -Eq "$NET_PATTERN"; then
  log "transient network error detected — retrying once after ${BACKOFF}s backoff"
  sleep "$BACKOFF"

  set +e
  git push -u "$REMOTE" "$BRANCH" 2> "$ATTEMPT_OUTPUT_FILE"
  rc=$?
  set -e
  cat "$ATTEMPT_OUTPUT_FILE" >&2

  if [ "$rc" -eq 0 ]; then
    log "pushed $BRANCH -> $REMOTE (after retry)"
    exit 0
  fi

  log "second push attempt also failed — giving up"
  exit 1
fi

# Non-network error — auth, perm, ref-mismatch. Fail-fast, no retry.
log "push failed (auth / permission / non-transient) — no retry"
exit 1
