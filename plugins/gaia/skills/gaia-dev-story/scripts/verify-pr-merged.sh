#!/usr/bin/env bash
# verify-pr-merged.sh — post-completion gate for gaia-dev-story (E20-S19)
#
# Verifies that a merge commit containing the story key exists on the target
# branch. Called by the orchestrator after the dev-story subagent returns
# status=done, before accepting the done transition.
#
# Covers both squash-merge and merge-commit strategies by searching the full
# git log (not just --merges) with a word-boundary pattern.
#
# Usage:
#   verify-pr-merged.sh <story_key> <target_branch>
#   verify-pr-merged.sh <story_key> --no-chain
#
# Environment:
#   PROJECT_PATH — optional. The git working directory (defaults to .).
#
# Exit codes:
#   0 — merge commit found on target branch (gate passes)
#   1 — usage/argument error
#   2 — no merge commit found (gate fails; orchestrator should re-run Steps 10-13)
#   3 — no promotion chain configured (gate skips silently)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/verify-pr-merged.sh"

# E20-S20: source the shared shell-idioms helper so we can use safe_grep_log
# instead of re-implementing the capture-then-grep SIGPIPE workaround inline.
# Resolve relative to this file so the script works from any cwd.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib" && pwd)/shell-idioms.sh"

# E53-S234 — Non-git CWD guard: skip-with-warning when CWD is outside any git
# work tree, so the post-completion gate degrades gracefully instead of
# returning exit 2 (which would force the orchestrator to re-run Steps 10-13).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib" && pwd)/non-git-cwd-guard.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "usage: verify-pr-merged.sh <story_key> <target_branch|--no-chain>"; exit 1; }

if [ $# -lt 2 ]; then
  die
fi

STORY_KEY="$1"
TARGET="$2"

# --no-chain: no promotion chain configured — skip silently
if [ "$TARGET" = "--no-chain" ]; then
  log "no promotion chain configured — gate skipped"
  exit 3
fi

WORK_DIR="${PROJECT_PATH:-.}"
cd "$WORK_DIR" || { log "cannot cd to $WORK_DIR"; exit 1; }

# Non-git CWD detection (post-cd so we check the resolved working directory).
non_git_cwd_skip "$SCRIPT_NAME" || exit 0

# Word-boundary grep pattern to avoid false positives (Val WARNING #2).
# Uses \b<key>\b as primary match. Falls back to "Story: <key>" pattern.
# Case-insensitive to handle squash-merge rewrites.
#
# E20-S20: the inline `git log | grep` SIGPIPE workaround used to live here.
# It is now centralised in safe_grep_log() (sourced above) so this script,
# and any future callers, no longer have to re-derive the trick.
PATTERN="\\b${STORY_KEY}\\b"

if safe_grep_log -i -q -E "$PATTERN" --oneline "$TARGET"; then
  log "merge commit for ${STORY_KEY} found on ${TARGET} — gate passes"
  exit 0
fi

# Fallback: check for "Story: <key>" in full commit messages
if safe_grep_log -i -q -E "Story:[[:space:]]*${STORY_KEY}\\b" --format='%B' "$TARGET"; then
  log "merge commit for ${STORY_KEY} found via Story: tag on ${TARGET} — gate passes"
  exit 0
fi

log "${STORY_KEY} not found on ${TARGET} — gate fails"
log "orchestrator should re-run Steps 10-13 (commit/push/PR/CI/merge)"
exit 2
