#!/usr/bin/env bash
# git-push.sh — shared push helper for GAIA dev/automation skills.
#
# Purpose:
#   Push the current branch to `origin` with retry logic for transient
#   errors.  Classifies push failures into five buckets and applies the
#   appropriate retry strategy.  Fails LOUDLY (non-zero exit) on auth /
#   permission / permanent-rejection errors — never silent.
#
# Usage:
#   git-push.sh [<remote>]
#
# Arguments:
#   <remote> — optional. The remote to push to. Defaults to "origin".
#
# Environment:
#   PROJECT_PATH — optional. The git working directory (defaults to .).
#                  Entered before any git operation, so the push acts on the
#                  repository named here rather than the caller's directory.
#                  The default keeps existing callers byte-identical.
#   GAIA_GIT_PUSH_BACKOFF — optional. Seconds to sleep between the first
#                            and second push attempt on a network retry.
#                            Default 5. Tests set this to 0 for speed.
#   GIT_PUSH_MAX_RETRIES — optional. Maximum number of retry attempts for
#                           transient remote rejections (bare "(failed)").
#                           Must be a non-negative integer; invalid values
#                           cause an immediate exit.  Leading zeros are
#                           normalised to base 10 (e.g. 08 -> 8).  Default 3.
#   GIT_PUSH_BACKOFF_BASE — optional. Base seconds for exponential backoff
#                            on transient remote rejections.  Delay per retry
#                            is BASE * 2^(attempt-1) (e.g. 2 -> 2/4/8).
#                            Must be a non-negative integer; invalid values
#                            cause an immediate exit.  Leading zeros are
#                            normalised to base 10 (e.g. 08 -> 8).  Default 2.
#
# Behavior:
#   1. Refuse to push if HEAD is on a protected branch (main / staging).
#      Delegates to lib/dev-story-security-invariants.sh::assert_branch_not_protected
#      when available; falls back to an inline check otherwise.
#   2. Run `git push -u <remote> <current-branch>`.
#      - Exit 0 on success.
#      - On non-zero exit, classify the error (applied in this order):
#          a. Auth / permission ("Authentication failed", "Permission denied",
#             "Permission to <repo> denied") -> exit non-zero immediately.
#          b. Permanent rejection — any [remote rejected] whose reason text
#             contains "hook declined" or "protected branch", or a mixed
#             output with any permanent reason -> exit non-zero immediately.
#          c. Transient rejection — [remote rejected] ... (failed) with NO
#             permanent reasons -> retry up to GIT_PUSH_MAX_RETRIES times
#             with bounded exponential backoff (BASE * 2^(n-1) seconds).
#             Each retry's output is re-classified in the same order
#             (auth -> permanent -> transient -> catch-all); a permanent
#             error on any attempt fails immediately.
#          d. Network indicators ("Could not resolve host", "Operation timed
#             out", "Connection refused", "Network is unreachable",
#             "TLS handshake") -> sleep $GAIA_GIT_PUSH_BACKOFF then retry
#             ONCE.
#          e. Catch-all — any other error -> exit non-zero immediately.
#
# Exit codes:
#   0 — push succeeded
#   1 — push failed (auth, perm, permanent rejection, exhausted retries,
#       two consecutive net errors, or unclassified error)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia/git-push.sh"
log()  { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { log "$*"; exit "${2:-1}"; }

REMOTE="${1:-origin}"
BACKOFF="${GAIA_GIT_PUSH_BACKOFF:-5}"
MAX_RETRIES="${GIT_PUSH_MAX_RETRIES:-3}"
BACKOFF_BASE="${GIT_PUSH_BACKOFF_BASE:-2}"

# Validate retry configuration — fail-closed on invalid input.
_validate_uint() {
  local name="$1" val="$2"
  case "$val" in
    ''|*[!0-9]*) die "$name must be a non-negative integer, got: '$val'" ;;
  esac
}
_validate_uint "GIT_PUSH_MAX_RETRIES" "$MAX_RETRIES"
_validate_uint "GIT_PUSH_BACKOFF_BASE" "$BACKOFF_BASE"

# Normalise to base 10 — prevents leading zeros from being interpreted
# as octal in arithmetic (e.g. 08 -> 8, 010 -> 10 not 8).
MAX_RETRIES=$((10#$MAX_RETRIES))
BACKOFF_BASE=$((10#$BACKOFF_BASE))

# Resolve the security-invariants library if present.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVARIANTS_LIB="$SCRIPT_DIR/lib/dev-story-security-invariants.sh"

# Working directory: resolve from PROJECT_PATH before any git operation. This
# comes after SCRIPT_DIR and INVARIANTS_LIB are derived from $0 above, so a
# relative invocation path still resolves the library correctly.
WORK_DIR="${PROJECT_PATH:-.}"
cd "$WORK_DIR" || die "cannot cd to $WORK_DIR"

# Non-git CWD guard: skip-with-warning when CWD is outside any git
# work tree, so dev-story steps degrade gracefully instead of HALT.
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

# ---------- 2. Push with classified retry ----------
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$BRANCH" ] || die "cannot determine current branch"

# Failure-classification patterns (checked in priority order).
AUTH_PATTERN='Authentication failed|Permission denied|Permission to .* denied'
PERM_REJECT_PATTERN='hook declined|protected branch'
TRANSIENT_REJECT_PATTERN='\[remote rejected\].*\(failed\)'
NET_PATTERN='Could not resolve host|Operation timed out|Connection refused|Network is unreachable|TLS handshake|Couldn'\''t connect|temporarily unavailable'

# Shared temp file for stderr capture across all push attempts.
ATTEMPT_OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$ATTEMPT_OUTPUT_FILE"' EXIT

# Run one push attempt, capturing stderr for classification.
# Writes to ATTEMPT_OUTPUT_FILE and echoes stderr back to the terminal.
# Returns the git push exit code.
_attempt_push() {
  local rc
  set +e
  git push -u "$REMOTE" "$BRANCH" 2>"$ATTEMPT_OUTPUT_FILE"
  rc=$?
  set -e
  cat "$ATTEMPT_OUTPUT_FILE" >&2
  return "$rc"
}

# Test whether the last push attempt's stderr matches a pattern.
_err_matches() {
  grep -Eq "$1" "$ATTEMPT_OUTPUT_FILE"
}

# --- First attempt ---
if _attempt_push; then
  log "pushed $BRANCH -> $REMOTE"
  exit 0
fi

# --- Classify the failure and retry where appropriate ---

# 1. Auth / permission — immediate fail, no retry.
if _err_matches "$AUTH_PATTERN"; then
  log "push failed (auth / permission) — no retry"
  exit 1
fi

# 2. Permanent rejection — immediate fail, no retry.
if _err_matches "$PERM_REJECT_PATTERN"; then
  log "push failed (permanent rejection) — no retry"
  exit 1
fi

# 3. Transient remote rejection — retry with bounded exponential backoff.
if _err_matches "$TRANSIENT_REJECT_PATTERN"; then
  attempt=0
  while [ "$attempt" -lt "$MAX_RETRIES" ]; do
    attempt=$((attempt + 1))
    delay=$((BACKOFF_BASE * (1 << (attempt - 1))))
    log "transient remote rejection — retry $attempt/$MAX_RETRIES after ${delay}s"
    sleep "$delay"

    if _attempt_push; then
      log "pushed $BRANCH -> $REMOTE (after retry)"
      exit 0
    fi

    # Re-classify — a permanent error on any attempt fails immediately.
    if _err_matches "$AUTH_PATTERN"; then
      log "push failed (auth / permission) — no retry"
      exit 1
    fi
    if _err_matches "$PERM_REJECT_PATTERN"; then
      log "push failed (permanent rejection) — no retry"
      exit 1
    fi
    if ! _err_matches "$TRANSIENT_REJECT_PATTERN"; then
      log "push failed (unclassified error) — no retry"
      exit 1
    fi
  done

  log "push failed after $MAX_RETRIES retries — last error: $(cat "$ATTEMPT_OUTPUT_FILE" || true)"
  exit 1
fi

# 4. Network error — retry ONCE.
if _err_matches "$NET_PATTERN"; then
  log "transient network error detected — retrying once after ${BACKOFF}s backoff"
  sleep "$BACKOFF"

  if _attempt_push; then
    log "pushed $BRANCH -> $REMOTE (after retry)"
    exit 0
  fi

  log "second push attempt also failed — giving up"
  exit 1
fi

# 5. Catch-all — unclassified error. No retry.
log "push failed (unclassified error) — no retry"
exit 1
