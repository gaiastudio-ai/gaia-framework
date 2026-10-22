#!/usr/bin/env bash
# git-branch.sh — gaia-dev-story feature branch creation
#
# Creates a feature branch following the git-workflow skill convention:
#   feat/{story_key}-{slug}
#
# Handles collision detection: if the branch already exists, offers resume
# instead of force-overwriting. Never destroys user work.
#
# Usage:
#   git-branch.sh <story_key> <slug>
#
# Environment:
#   PROJECT_PATH — required. The git working directory.
#
# Exit codes:
#   0 — branch created or already exists (resume)
#   1 — error (no git repo, invalid args, etc.)

set -euo pipefail
_ORIG_LC_ALL="${LC_ALL:-}"
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/git-branch.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# Non-git CWD guard: skip-with-warning when CWD is outside any git
# work tree. Replaces the prior `die "not a git repository"` so steps
# degrade gracefully when project-root has no .git.
# shellcheck source=../../../scripts/lib/non-git-cwd-guard.sh
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$GUARD_DIR/../../../scripts/lib/non-git-cwd-guard.sh"

if [ $# -lt 2 ]; then
  die "usage: git-branch.sh <story_key> <slug>"
fi

STORY_KEY="$1"
SLUG="$2"

# Apply the same slug cap as worktree_create so branch names stay consistent.
# Source the library and call worktree_slug_cap directly — this keeps the cap
# value, locale handling, and truncation logic in a single place.
# The call runs in the caller's original locale so that cut(1) counts
# characters, matching how worktree_create invokes the same function.
# shellcheck source=../../../scripts/lib/story-worktree.sh
. "$GUARD_DIR/../../../scripts/lib/story-worktree.sh"
SLUG="$(LC_ALL="${_ORIG_LC_ALL:-}" worktree_slug_cap "$SLUG")"
BRANCH_NAME="feat/${STORY_KEY}-${SLUG}"

WORK_DIR="${PROJECT_PATH:-.}"
cd "$WORK_DIR" || die "cannot cd to $WORK_DIR"

# Non-git CWD detection (post-cd so we check the resolved working directory).
# Replaces the prior `die` semantics; non-git CWD now exits 0 with a warning.
non_git_cwd_skip "$SCRIPT_NAME" || exit 0

# Worktree dedup: if the working directory is a linked worktree that already
# has a feat/<story-key>-* branch checked out (possibly truncated differently),
# reuse that branch instead of creating a second one.
_current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
if [ -n "$_current_branch" ] && [ "$_current_branch" != "$BRANCH_NAME" ]; then
  case "$_current_branch" in
    "feat/${STORY_KEY}-"*)
      log "reusing worktree branch '$_current_branch' (matches story key)"
      echo "already exists: $_current_branch"
      exit 0
      ;;
  esac
fi

# Check if the branch already exists (local)
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
  log "branch '$BRANCH_NAME' already exists — collision detected"
  log "to resume work on this branch: git checkout $BRANCH_NAME"
  echo "already exists: $BRANCH_NAME"
  exit 0
fi

# Check if the branch exists on remote
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH_NAME" 2>/dev/null; then
  log "branch '$BRANCH_NAME' exists on remote — checking out"
  git checkout -b "$BRANCH_NAME" "origin/$BRANCH_NAME" 2>&1
  echo "checked out from remote: $BRANCH_NAME"
  exit 0
fi

# Create the branch from current HEAD
git checkout -b "$BRANCH_NAME" 2>&1
log "created branch: $BRANCH_NAME"
echo "created: $BRANCH_NAME"
exit 0
