#!/usr/bin/env bash
# git-branch.sh — gaia-dev-story feature branch creation (E28-S53)
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
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/git-branch.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# E53-S234 — Non-git CWD guard: skip-with-warning when CWD is outside any git
# work tree. Replaces the prior `die "not a git repository"` so Steps 10-13
# degrade gracefully when project-root has no .git.
# shellcheck source=../../../scripts/lib/non-git-cwd-guard.sh
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$GUARD_DIR/../../../scripts/lib/non-git-cwd-guard.sh"

if [ $# -lt 2 ]; then
  die "usage: git-branch.sh <story_key> <slug>"
fi

STORY_KEY="$1"
SLUG="$2"
BRANCH_NAME="feat/${STORY_KEY}-${SLUG}"

WORK_DIR="${PROJECT_PATH:-.}"
cd "$WORK_DIR" || die "cannot cd to $WORK_DIR"

# Non-git CWD detection (post-cd so we check the resolved working directory).
# Replaces the prior `die` semantics; non-git CWD now exits 0 with a warning.
non_git_cwd_skip "$SCRIPT_NAME" || exit 0

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
