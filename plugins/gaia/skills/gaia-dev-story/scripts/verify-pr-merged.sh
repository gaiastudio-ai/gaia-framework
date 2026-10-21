#!/usr/bin/env bash
# verify-pr-merged.sh — post-completion gate for gaia-dev-story
#
# Verifies that the story's pull request has actually been merged by checking
# the GitHub API (`gh pr list` + merge status), rather than grepping commit
# messages which can false-pass when an older commit mentions the story key.
#
# When the `gh` CLI is unavailable or the API call fails, falls back to the
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

# check_pr_via_api — query gh for PRs matching the story key, then check
# the feature-branch PR's merge status. Returns 0 (merged), 2 (not merged),
# or 1 (API unavailable — caller should fall back).
check_pr_via_api() {
  # Guard: gh must be on PATH.
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh CLI not found on PATH — falling back to commit-based check"
    return 1
  fi

  # Query for PRs whose head branch contains the story key (the feature
  # branch convention is feat/<story_key>-<slug>).
  local pr_json
  if ! pr_json="$(gh pr list \
        --search "$STORY_KEY" \
        --state all \
        --json number,headRefName,state,mergedAt \
        --limit 50 2>/dev/null)"; then
    warn "gh pr list failed — falling back to commit-based check"
    return 1
  fi

  # Empty or null response means no PRs found.
  if [ -z "$pr_json" ] || [ "$pr_json" = "[]" ] || [ "$pr_json" = "null" ]; then
    log "no PRs found matching ${STORY_KEY} — gate fails"
    log "orchestrator should re-run the commit/push/PR/CI/merge steps"
    exit 2
  fi

  # Find the feature-branch PR: its headRefName starts with "feat/<story_key>".
  # Use a simple line-by-line parse that works without jq (bash 3.2 safe).
  local feature_merged=""
  local feature_found=0
  local key_lower
  # Lowercase the story key for case-insensitive branch matching.
  # bash 3.2 safe: use tr instead of ${var,,}.
  key_lower="$(printf '%s' "$STORY_KEY" | tr '[:upper:]' '[:lower:]')"

  # Normalise compact JSON to one-field-per-line so the line-by-line parser
  # works whether gh outputs pretty-printed or compact JSON.  The sed chain:
  #   1. split on },{ boundaries (object separator)
  #   2. split on ," boundaries (field separator inside an object)
  #   3. put } on its own line (end-of-object marker for the parser)
  local pr_lines
  pr_lines="$(printf '%s\n' "$pr_json" \
    | sed 's/},{/}\
{/g' \
    | sed 's/,"/\
"/g' \
    | sed 's/}/\
}/g')"

  local current_head="" current_merged=""
  while IFS= read -r line; do
    case "$line" in
      *'"headRefName"'*)
        current_head="$(printf '%s' "$line" | sed 's/.*"headRefName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
        ;;
      *'"mergedAt"'*)
        # Extract mergedAt value; handles both "mergedAt":"2026..." and "mergedAt":"".
        current_merged="$(printf '%s' "$line" | sed 's/.*"mergedAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
        ;;
      *'}'*)
        # End of an object — check if this is the feature PR.
        if [ -n "$current_head" ]; then
          local head_lower
          head_lower="$(printf '%s' "$current_head" | tr '[:upper:]' '[:lower:]')"
          case "$head_lower" in
            feat/"$key_lower"*)
              feature_found=1
              if [ -n "$current_merged" ]; then
                feature_merged="$current_merged"
              fi
              ;;
          esac
        fi
        current_head=""
        current_merged=""
        ;;
    esac
  done <<EOF
$pr_lines
EOF

  if [ "$feature_found" -eq 0 ]; then
    log "no feature-branch PR found for ${STORY_KEY} — gate fails"
    log "orchestrator should re-run the commit/push/PR/CI/merge steps"
    exit 2
  fi

  if [ -n "$feature_merged" ]; then
    log "PR for ${STORY_KEY} merged at ${feature_merged} on ${TARGET} — gate passes"
    return 0
  fi

  log "PR for ${STORY_KEY} exists but is not merged — gate fails"
  log "orchestrator should re-run the commit/push/PR/CI/merge steps"
  exit 2
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
