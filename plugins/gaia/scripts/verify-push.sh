#!/usr/bin/env bash
# verify-push.sh — post-step push-verification helper for GAIA dev/automation skills.
#
# Purpose:
#   After a feature branch has been pushed (e.g. by git-push.sh), assert that
#   `git ls-remote --heads <remote> <branch>` reports the same sha as local
#   HEAD. Catches silent push failures (network partition, ref-update rejected,
#   stale credentials) so the calling skill cannot mark a story `done` while
#   the remote branch is unpublished or out of sync.
#
#   Motivation: dev-story finalize reported success while the local branch
#   never made it to origin.
#
# Usage:
#   verify-push.sh [<remote>]
#
# Arguments:
#   <remote> — optional. Remote to query. Defaults to "origin".
#              Overridable via GAIA_VERIFY_PUSH_REMOTE.
#
# Environment:
#   GAIA_PUSH_VERIFY=skip — bypass verification entirely (exit 0 silently).
#                            Use for local/dev runs that don't push.
#   GAIA_VERIFY_PUSH_REMOTE — alternate remote name. Default "origin".
#
# Behavior:
#   1. Skip-with-warning when CWD is outside any git work tree
#      (delegates to lib/non-git-cwd-guard.sh).
#   2. Skip exit-0 silently when current branch is `main` / `staging`
#      (those workflows never push from a feature flow).
#   3. Skip exit-0 when GAIA_PUSH_VERIFY=skip.
#   4. Run `git ls-remote --heads <remote> <branch>`.
#      - No output / branch missing on remote -> exit 1 (diagnostic includes
#        branch name, sprint-37 incident reference).
#      - Output's sha != local HEAD sha -> exit 1 (diagnostic names both shas).
#      - Output's sha == local HEAD sha -> exit 0 (silent on success).
#
# Exit codes:
#   0 — verification passed (or skipped per guard / env).
#   1 — verification failed (sha mismatch or branch absent on remote).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia/verify-push.sh"
log()  { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { log "$*"; exit "${2:-1}"; }

REMOTE="${1:-${GAIA_VERIFY_PUSH_REMOTE:-origin}}"

# Resolve the non-git-cwd guard library.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/non-git-cwd-guard.sh
. "$SCRIPT_DIR/lib/non-git-cwd-guard.sh"
non_git_cwd_skip "$SCRIPT_NAME" || exit 0

# ---------- 1. Env-override skip ----------
if [ "${GAIA_PUSH_VERIFY:-}" = "skip" ]; then
  log "skipped (GAIA_PUSH_VERIFY=skip)"
  exit 0
fi

# ---------- 2. Resolve current branch ----------
# Detached HEAD (CI PR checkouts, audit fixtures) and empty repos cannot have
# a branch to verify — silently skip exit 0. Real push workflows always run
# from a named feature branch.
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  log "skipped (detached HEAD or empty repo — no branch to verify)"
  exit 0
fi

# ---------- 3. Protected-branch silent skip ----------
case "$BRANCH" in
  main|staging)
    # Feature-branch workflows never push from main / staging. Silent skip.
    exit 0
    ;;
esac

# ---------- 4. Local HEAD sha ----------
LOCAL_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
[ -n "$LOCAL_SHA" ] || die "cannot resolve local HEAD sha"

# ---------- 5. Query remote ----------
LSREMOTE_OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$LSREMOTE_OUTPUT_FILE"' EXIT

set +e
git ls-remote --heads "$REMOTE" "$BRANCH" > "$LSREMOTE_OUTPUT_FILE" 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  err_text="$(cat "$LSREMOTE_OUTPUT_FILE" 2>/dev/null || true)"
  log "git ls-remote failed (rc=$rc): $err_text"
  exit 1
fi

# ---------- 6. Parse remote sha ----------
REMOTE_LINE="$(head -n 1 "$LSREMOTE_OUTPUT_FILE" 2>/dev/null || true)"

if [ -z "$REMOTE_LINE" ]; then
  log "branch '$BRANCH' not found on remote '$REMOTE' — push silently dropped or never executed"
  log "  hint: re-run git-push.sh and inspect output for auth / network errors"
  exit 1
fi

REMOTE_SHA="$(printf '%s' "$REMOTE_LINE" | awk '{print $1}')"

if [ -z "$REMOTE_SHA" ]; then
  die "could not parse remote sha from ls-remote output: '$REMOTE_LINE'"
fi

# ---------- 7. Compare ----------
if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
  log "sha mismatch — local HEAD differs from remote '$REMOTE/$BRANCH'"
  log "  local:  $LOCAL_SHA"
  log "  remote: $REMOTE_SHA"
  log "  hint: a previous push may have been silently rejected; inspect git-push.sh output"
  exit 1
fi

# Verification passed — silent on success.
exit 0
