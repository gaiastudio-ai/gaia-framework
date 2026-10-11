#!/usr/bin/env bash
# pr-create.sh — gaia-dev-story PR creation
#
# Creates a pull request targeting the first promotion chain environment.
# Uses the gh CLI for GitHub Actions (the default CI provider).
#
# Validates the title as a conventional-commit line, passes it through as-is,
# appends a Story: body reference when absent, and reports errors with
# preserved local commits.
#
# Usage:
#   pr-create.sh <story_key> <title> [--base <branch>] [--body-file <path> | -F <path>]
#
# When --body-file (or -F) is passed, the file content is used as the
# PR body — the default body is bypassed. A `Story: <key>` reference line
# is appended when the body does not already carry one (anchored to line
# start).
# SKILL.md Step 11 instructs callers to feed `pr-body.sh` output through this flag.
#
# Environment:
#   PROJECT_PATH — required. The git working directory. Resolved and entered
#                  BEFORE the non-git guard runs and before arguments are
#                  parsed, so relative path arguments resolve against it.
#
# Exit codes:
#   0 — PR created or already exists
#   1 — error (invalid title, no gh CLI, auth failure, network error, etc.)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/pr-create.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# Security invariants sourced from the canonical lib at
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

# Non-git CWD guard: skip-with-warning when CWD is outside any git work tree.
# Runs BEFORE security invariants so a non-git CWD never reaches the
# protected-branch / staged-secrets checks.
# shellcheck source=../../../scripts/lib/non-git-cwd-guard.sh
. "$SCRIPT_DIR/../../../scripts/lib/non-git-cwd-guard.sh"
# Resolve the working directory BEFORE the non-git guard: the guard reads
# CWD, so it must test the directory this script is meant to act on, not the
# caller's. Argument parsing follows, so relative path arguments resolve
# against PROJECT_PATH.
WORK_DIR="${PROJECT_PATH:-.}"
cd "$WORK_DIR" || die "cannot cd to $WORK_DIR"

non_git_cwd_skip "$SCRIPT_NAME" || exit 0

if [ $# -lt 2 ]; then
  die "usage: pr-create.sh <story_key> <title> [--base <branch>] [--body-file <path> | -F <path>]"
fi

STORY_KEY="$1"
PR_TITLE="$2"
shift 2

BASE_BRANCH="staging"
BODY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_BRANCH="$2"; shift 2 ;;
    --body-file|-F) BODY_FILE="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [ -n "$BODY_FILE" ] && [ ! -r "$BODY_FILE" ]; then
  die "--body-file path is not readable: $BODY_FILE"
fi

# --- Title validation: must be a single conventional-commit line -----------
# Refuse multi-line titles (LF or CR) and bare/non-conventional titles.
# The regex matches: <type>[(<scope>)][!]: <subject>
case "$PR_TITLE" in
  *$'\n'*|*$'\r'*)
    die "title must be a single conventional-commit line (e.g., 'fix: …' / 'feat(scope): …') — got multi-line input"
    ;;
esac
cc_re='^[a-z]+(\([^)]+\))?!?: [^ ]'
if ! [[ "$PR_TITLE" =~ $cc_re ]]; then
  die "title must be a single conventional-commit line (e.g., 'fix: …' / 'feat(scope): …') — got: $PR_TITLE"
fi

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

# Enforce security invariants BEFORE any push or PR creation.
# These are hard gates; YOLO mode does not bypass.
assert_branch_not_protected || die "aborting: protected-branch invariant failed"
assert_no_secrets_staged || die "aborting: staged-secrets invariant failed"

# Build PR body. When --body-file was passed, read its content;
# otherwise fall back to the default body that points at the story file.
# Either way, a Story: reference is appended below when absent.
if [ -n "$BODY_FILE" ]; then
  PR_BODY="$(cat "$BODY_FILE")"
else
  PR_BODY="## ${STORY_KEY}

### Acceptance Criteria

See story file: .gaia/artifacts/implementation-artifacts/epic-*/stories/${STORY_KEY}-*.md — legacy-flat fallback: docs/implementation-artifacts/${STORY_KEY}-*.md

Story: ${STORY_KEY}"
fi

# Title already validated as conventional-commit format — pass through as-is.
FINAL_TITLE="$PR_TITLE"

# Ensure the body contains a Story: reference line. When the body already has
# one (plain or link form), skip. Otherwise append it.
if ! grep -qE '^Story:' <<<"$PR_BODY"; then
  PR_BODY="$(printf '%s\n\nStory: %s' "$PR_BODY" "$STORY_KEY")"
fi

# Create PR
pr_output=$(gh pr create --base "$BASE_BRANCH" --title "$FINAL_TITLE" --body "$PR_BODY" 2>&1) || {
  log "PR creation failed:"
  printf '%s\n' "$pr_output" >&2
  log "Local commits are preserved. Re-run after resolving the issue."
  exit 1
}

log "PR created: $pr_output"
echo "created:${pr_output}"
exit 0
