#!/usr/bin/env bash
# pr-create.sh — gaia-dev-story PR creation (E28-S53)
#
# Creates a pull request targeting the first promotion chain environment.
# Uses the gh CLI for GitHub Actions (the default CI provider).
#
# Handles: existing PR detection, conventional title construction, story-key
# body inclusion, and error reporting with preserved local commits.
#
# Usage:
#   pr-create.sh <story_key> <title> [--base <branch>]
#
# Environment:
#   PROJECT_PATH — required. The git working directory.
#
# Exit codes:
#   0 — PR created or already exists
#   1 — error (no gh CLI, auth failure, network error, etc.)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/pr-create.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# E55-S6 — TB-10 security invariants. Sourced from the canonical lib at
# plugins/gaia/scripts/lib/dev-story-security-invariants.sh. Hard rule:
# YOLO mode MUST NOT bypass these assertions.
# shellcheck source=../../../scripts/lib/dev-story-security-invariants.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVARIANTS_LIB="$SCRIPT_DIR/../../../scripts/lib/dev-story-security-invariants.sh"
if [ ! -f "$INVARIANTS_LIB" ]; then
  die "security-invariant lib missing at $INVARIANTS_LIB"
fi
# shellcheck disable=SC1090
source "$INVARIANTS_LIB"

# E53-S234 — Non-git CWD guard: skip-with-warning when CWD is outside any git
# work tree. Runs BEFORE security invariants so a non-git CWD never reaches
# the protected-branch / staged-secrets checks.
# shellcheck source=../../../scripts/lib/non-git-cwd-guard.sh
. "$SCRIPT_DIR/../../../scripts/lib/non-git-cwd-guard.sh"
non_git_cwd_skip "$SCRIPT_NAME" || exit 0

if [ $# -lt 2 ]; then
  die "usage: pr-create.sh <story_key> <title> [--base <branch>]"
fi

STORY_KEY="$1"
PR_TITLE="$2"
shift 2

BASE_BRANCH="staging"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_BRANCH="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

WORK_DIR="${PROJECT_PATH:-.}"
cd "$WORK_DIR" || die "cannot cd to $WORK_DIR"

# Verify gh CLI is available
if ! command -v gh >/dev/null 2>&1; then
  die "Required tool gh not found. Install it or complete PR creation manually."
fi

# Get current branch
BRANCH_NAME=$(git branch --show-current 2>/dev/null) || die "cannot determine current branch"

# Check for existing PR
existing_pr=$(gh pr list --head "$BRANCH_NAME" --base "$BASE_BRANCH" --json number,url --jq '.[0]' 2>/dev/null || echo "")
if [ -n "$existing_pr" ] && [ "$existing_pr" != "null" ]; then
  pr_number=$(echo "$existing_pr" | grep -o '"number":[0-9]*' | grep -o '[0-9]*' || echo "")
  pr_url=$(echo "$existing_pr" | grep -o '"url":"[^"]*"' | sed 's/"url":"//;s/"$//' || echo "")
  log "PR #${pr_number} already exists — proceeding to CI check"
  echo "existing:${pr_number}:${pr_url}"
  exit 0
fi

# E55-S6 — Enforce TB-10 security invariants BEFORE any push or PR creation.
# These are hard gates; YOLO mode does not bypass.
assert_branch_not_protected || die "aborting: protected-branch invariant failed"
assert_no_secrets_staged || die "aborting: staged-secrets invariant failed"

# Build PR body
PR_BODY="## ${STORY_KEY}

### Acceptance Criteria

See story file: docs/implementation-artifacts/epic-*/stories/${STORY_KEY}-*.md (canonical, E79) — legacy-flat fallback: docs/implementation-artifacts/${STORY_KEY}-*.md

Story: ${STORY_KEY}"

# Create PR
pr_output=$(gh pr create --base "$BASE_BRANCH" --title "${STORY_KEY}: ${PR_TITLE}" --body "$PR_BODY" 2>&1) || {
  log "PR creation failed:"
  printf '%s\n' "$pr_output" >&2
  log "Local commits are preserved. Re-run after resolving the issue."
  exit 1
}

log "PR created: $pr_output"
echo "created:${pr_output}"
exit 0
