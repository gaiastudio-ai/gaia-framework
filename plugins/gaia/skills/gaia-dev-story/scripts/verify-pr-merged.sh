#!/usr/bin/env bash
# verify-pr-merged.sh — post-completion gate for gaia-dev-story
#
# Verifies that the story's pull request has actually been merged by checking
# the GitHub API (gh pr list with --jq filtering by feature-branch prefix,
# target branch, and state), rather than grepping commit messages which can
# false-pass when an older commit mentions the story key.
#
# When the gh CLI is unavailable or the API call fails, falls back to the
# legacy commit-grep check with a WARNING so the degradation is auditable.
#
# Usage:
#   verify-pr-merged.sh <story_key> <target_branch>
#   verify-pr-merged.sh <story_key> --no-chain
#
# Environment:
#   PROJECT_PATH — optional. The git working directory (defaults to .).
#
# Exit codes:
#   0 — PR merged on target branch (gate passes)
#   1 — usage/argument error
#   2 — PR not merged / not found (gate fails)
#   3 — no promotion chain configured (gate skips silently)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/verify-pr-merged.sh"

# Source the shared shell-idioms helper so we can use safe_grep_log instead of
# re-implementing the capture-then-grep SIGPIPE workaround inline.
# Resolve relative to this file so the script works from any cwd.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib" && pwd)/shell-idioms.sh"

# Non-git CWD guard: skip-with-warning when CWD is outside any git work tree,
# so the post-completion gate degrades gracefully instead of returning exit 2
# (which would force the orchestrator to re-run the commit/push/PR/CI/merge steps).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib" && pwd)/non-git-cwd-guard.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
warn() { printf '%s: WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2; }
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

# ---------------------------------------------------------------------------
# Primary path: check PR merge status via the GitHub API.
# ---------------------------------------------------------------------------

# check_pr_via_api — query gh for the feature-branch PR's state. Uses gh's
# built-in --jq to filter by branch prefix and target branch, then extract
# the state.  Avoids manual JSON parsing entirely.
#
# Returns 0 (merged) or exits 2 (not merged / not found).
# Returns 1 when the API is unavailable and the caller should fall back.
check_pr_via_api() {
  # Guard: gh must be on PATH.
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh CLI not found on PATH — falling back to commit-based check"
    return 1
  fi

  # Lowercase the story key for case-insensitive branch matching.
  # bash 3.2 safe: use tr instead of ${var,,}.
  local key_lower
  key_lower="$(printf '%s' "$STORY_KEY" | tr '[:upper:]' '[:lower:]')"
  local target_lower
  target_lower="$(printf '%s' "$TARGET" | tr '[:upper:]' '[:lower:]')"

  # Use gh's built-in --jq to:
  #   1. Filter PRs whose headRefName starts with "feat/<key>-" (trailing dash
  #      prevents prefix collisions: key S1 must not match branch S10).
  #   2. Filter PRs whose baseRefName matches the target branch.
  #   3. When multiple PRs match, report the newest (last in the array, which
  #      gh returns sorted by creation date descending). If any is OPEN or
  #      CLOSED, the gate must not pass on a stale MERGED PR — so we pick
  #      the first (newest) entry's state.
  #   4. Return "NO_MATCH" when no PR matches the filters.
  # Deciding by state (MERGED vs OPEN/CLOSED) avoids the null-vs-empty
  # mergedAt parsing bug that broke the original sed-based approach.
  local pr_state
  if ! pr_state="$(gh pr list \
        --state all \
        --json headRefName,baseRefName,state \
        --limit 200 \
        --jq '[.[] | select((.headRefName | ascii_downcase | startswith("feat/'"${key_lower}"'-")) and (.baseRefName | ascii_downcase == "'"${target_lower}"'"))] | if length == 0 then "NO_MATCH" else .[0].state end' \
        2>/dev/null)"; then
    warn "gh pr list failed — falling back to commit-based check"
    return 1
  fi

  # Empty output means gh produced nothing useful (parse failure, etc.).
  # Fail closed: fall back rather than silently passing.
  if [ -z "$pr_state" ]; then
    warn "gh pr list returned empty output — falling back to commit-based check"
    return 1
  fi

  case "$pr_state" in
    NO_MATCH)
      log "no feature-branch PR found for ${STORY_KEY} targeting ${TARGET} — gate fails"
      log "orchestrator should re-run the commit/push/PR/CI/merge steps"
      exit 2
      ;;
    MERGED)
      log "PR for ${STORY_KEY} merged on ${TARGET} — gate passes"
      return 0
      ;;
    *)
      log "PR for ${STORY_KEY} exists (state: ${pr_state}) but is not merged — gate fails"
      log "orchestrator should re-run the commit/push/PR/CI/merge steps"
      exit 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Commit-grep fallback (legacy logic, used only when gh is unavailable).
# ---------------------------------------------------------------------------

commit_grep_fallback() {
  local pattern="\\b${STORY_KEY}\\b"

  if safe_grep_log -i -q -E "$pattern" --oneline "$TARGET"; then
    log "merge commit for ${STORY_KEY} found on ${TARGET} via commit grep (fallback) — gate passes"
    return 0
  fi

  # Secondary fallback: "Story: <key>" in full commit bodies (plain or link form).
  if safe_grep_log -i -q -E "Story:[[:space:]]*\[?${STORY_KEY}(\]|\\b)" --format='%B' "$TARGET"; then
    log "merge commit for ${STORY_KEY} found via Story: tag on ${TARGET} (fallback) — gate passes"
    return 0
  fi

  log "${STORY_KEY} not found on ${TARGET} — gate fails"
  log "orchestrator should re-run the commit/push/PR/CI/merge steps"
  exit 2
}

# ---------------------------------------------------------------------------
# Main flow: try API first, fall back to commit grep.
# ---------------------------------------------------------------------------

if check_pr_via_api; then
  exit 0
fi

# check_pr_via_api returned 1 (API unavailable) — use the commit-grep fallback.
commit_grep_fallback
exit 0
