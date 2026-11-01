#!/usr/bin/env bash
# verify-pr-merged.sh — post-completion gate for gaia-dev-story
#
# Verifies that the story's pull request has actually been merged by checking
# the GitHub API (gh pr list with head-branch search and --jq filtering by
# feature-branch prefix, target branch, and merge state), rather than grepping
# commit messages which can false-pass when an older commit mentions the story
# key.
#
# When the gh CLI is unavailable or the API call fails, falls back to the
# legacy commit-grep check with a WARNING so the degradation is auditable.
#
# Usage:
#   verify-pr-merged.sh <story_key> <target_branch>
#   verify-pr-merged.sh <story_key> --no-chain
#
# The <target_branch> may include a remote prefix (e.g. "origin/staging")
# or a refs/ prefix; only a known git remote is stripped, so multi-segment
# branch names like "release/next" are preserved.
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

# ---------------------------------------------------------------------------
# Input validation — fail closed on unexpected characters.
# The key and target are spliced into the jq program text (gh --jq has no
# --arg equivalent), so they must be validated before use.
# ---------------------------------------------------------------------------

# Story key: alphanumeric segments separated by a single dash.
if ! printf '%s' "$STORY_KEY" | /usr/bin/grep -qE '^[A-Za-z0-9]+-[A-Za-z0-9]+$'; then
  log "invalid story key format: ${STORY_KEY}"
  exit 1
fi

# Target branch: allowlist prevents jq injection via crafted branch names.
if ! printf '%s' "$TARGET" | /usr/bin/grep -qE '^[A-Za-z0-9._/-]+$'; then
  log "invalid target branch: ${TARGET}"
  exit 1
fi

# Keep the full ref for the commit-grep fallback (needs remote-qualified form).
TARGET_FULL="$TARGET"

WORK_DIR="${PROJECT_PATH:-.}"
cd "$WORK_DIR" || { log "cannot cd to $WORK_DIR"; exit 1; }

# Non-git CWD detection (post-cd so we check the resolved working directory).
non_git_cwd_skip "$SCRIPT_NAME" || exit 0

# ---------------------------------------------------------------------------
# Strip remote prefix from TARGET to get the bare branch name for the API.
# Only strip a known git remote or refs/ prefix — multi-segment branch names
# like "release/next" must be preserved.
# ---------------------------------------------------------------------------

# strip_remote_prefix <ref>
# Outputs the bare branch name.  Strips, in order:
#   1. refs/heads/        → bare
#   2. refs/remotes/<r>/  → bare (where <r> is a configured remote)
#   3. <r>/               → bare (where <r> is a configured remote)
# If no prefix matches, returns the input unchanged.
strip_remote_prefix() {
  local ref="$1"

  # Strip refs/heads/
  case "$ref" in
    refs/heads/*) printf '%s' "${ref#refs/heads/}"; return ;;
  esac

  # Build list of configured remotes (one per line).
  local remotes
  remotes="$(git remote 2>/dev/null)" || true

  local r
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    # Strip refs/remotes/<remote>/
    case "$ref" in
      "refs/remotes/${r}/"*) printf '%s' "${ref#refs/remotes/"${r}"/}"; return ;;
    esac
    # Strip <remote>/
    case "$ref" in
      "${r}/"*) printf '%s' "${ref#"${r}"/}"; return ;;
    esac
  done <<EOF
$remotes
EOF

  # No known prefix — return unchanged.
  printf '%s' "$ref"
}

BASE_BRANCH="$(strip_remote_prefix "$TARGET")"

# Validate the base branch name via git check-ref-format.
if ! git check-ref-format --allow-onelevel "refs/heads/${BASE_BRANCH}" 2>/dev/null; then
  log "invalid target branch: ${BASE_BRANCH}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Fetch the target branch for robustness: ensures the local ref is up to
# date before the API query and the commit-based fallback.
# ---------------------------------------------------------------------------
if git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null; then
  : # fetched successfully
else
  warn "git fetch origin ${BASE_BRANCH} failed — proceeding with local refs"
fi

# ---------------------------------------------------------------------------
# Primary path: check PR merge status via the GitHub API.
# ---------------------------------------------------------------------------

# check_pr_via_api — query gh for the feature-branch PR's state. Uses gh's
# --search "head:feat/<key>-" to target the query at the right head branch
# (avoids the 200-PR window limit), then --jq to filter by base branch and
# extract the state.  When the search index returns not-merged, confirms
# with gh pr view (exact, no search lag).
#
# Returns 0 (merged) or exits 2 (not merged / not found).
# Returns 1 when the API is unavailable and the caller should fall back.
check_pr_via_api() {
  # Guard: gh must be on PATH.
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh CLI not found on PATH — falling back to commit-based check"
    return 1
  fi

  # Lowercase for case-insensitive matching.
  # bash 3.2 safe: use tr instead of ${var,,}.
  local key_lower
  key_lower="$(printf '%s' "$STORY_KEY" | tr '[:upper:]' '[:lower:]')"
  local base_lower
  base_lower="$(printf '%s' "$BASE_BRANCH" | tr '[:upper:]' '[:lower:]')"

  # Use --search "head:feat/<key>-" to narrow the query to PRs whose head
  # branch starts with the feature-branch prefix.
  #
  # The --jq filter:
  #   1. Requires headRefName starts with "feat/<key>-" (trailing dash
  #      prevents prefix collisions).
  #   2. Requires baseRefName matches the target branch.
  #   3. Requires state == "MERGED" AND mergedAt is non-null.
  #   4. The newest PR (first in gh's creation-desc order) determines the
  #      result.  If the newest is not merged, the gate fails.
  #   5. Returns "NO_MATCH" when no PR matches, or "<state>:<number>" for
  #      the newest matching PR so we can confirm via gh pr view.
  local pr_result
  if ! pr_result="$(gh pr list \
        --state all \
        --search "head:feat/${key_lower}-" \
        --json number,headRefName,baseRefName,state,mergedAt \
        --limit 200 \
        --jq '[.[] | select((.headRefName | ascii_downcase | startswith("feat/'"${key_lower}"'-")) and (.baseRefName | ascii_downcase == "'"${base_lower}"'"))] | if length == 0 then "NO_MATCH" elif (.[0].state == "MERGED" and .[0].mergedAt != null) then "MERGED" else "\(.[0].state):\(.[0].number)" end' \
        2>/dev/null)"; then
    warn "gh pr list failed — falling back to commit-based check"
    return 1
  fi

  # Empty output means gh produced nothing useful (parse failure, etc.).
  # Fail closed: fall back rather than silently passing.
  if [ -z "$pr_result" ]; then
    warn "gh pr list returned empty output — falling back to commit-based check"
    return 1
  fi

  case "$pr_result" in
    NO_MATCH)
      log "no feature-branch PR found for ${STORY_KEY} targeting ${BASE_BRANCH} — gate fails"
      log "orchestrator should re-run the commit/push/PR/CI/merge steps"
      exit 2
      ;;
    MERGED)
      log "PR for ${STORY_KEY} merged on ${BASE_BRANCH} — gate passes"
      return 0
      ;;
    *)
      # The search index may lag after a fresh merge (~1 s).  Confirm with
      # gh pr view (exact lookup, no search index) before failing.
      local pr_num="${pr_result#*:}"
      if [ -n "$pr_num" ] && confirm_pr_merged "$pr_num"; then
        log "PR for ${STORY_KEY} (#${pr_num}) confirmed merged on ${BASE_BRANCH} — gate passes"
        return 0
      fi
      local pr_state="${pr_result%%:*}"
      log "PR for ${STORY_KEY} exists (state: ${pr_state}) but is not merged — gate fails"
      log "orchestrator should re-run the commit/push/PR/CI/merge steps"
      exit 2
      ;;
  esac
}

# confirm_pr_merged <pr_number>
# Exact lookup via gh pr view to confirm a PR is merged (bypasses search lag).
# Returns 0 if MERGED with non-null mergedAt, 1 otherwise.
confirm_pr_merged() {
  local num="$1"
  local view_result
  if ! view_result="$(gh pr view "$num" \
        --json state,mergedAt \
        --jq 'if .state == "MERGED" and .mergedAt != null then "MERGED" else "NOT_MERGED" end' \
        2>/dev/null)"; then
    return 1
  fi
  [ "$view_result" = "MERGED" ]
}

# ---------------------------------------------------------------------------
# Commit-grep fallback (legacy logic, used only when gh is unavailable).
# Uses TARGET_FULL (may include remote prefix) for git log resolution.
# ---------------------------------------------------------------------------

commit_grep_fallback() {
  local pattern="\\b${STORY_KEY}\\b"

  if safe_grep_log -i -q -E "$pattern" --oneline "$TARGET_FULL"; then
    log "merge commit for ${STORY_KEY} found on ${TARGET_FULL} via commit grep (fallback) — gate passes"
    return 0
  fi

  # Secondary fallback: "Story: <key>" in full commit bodies (plain or link form).
  if safe_grep_log -i -q -E "Story:[[:space:]]*\[?${STORY_KEY}(\]|\\b)" --format='%B' "$TARGET_FULL"; then
    log "merge commit for ${STORY_KEY} found via Story: tag on ${TARGET_FULL} (fallback) — gate passes"
    return 0
  fi

  log "${STORY_KEY} not found on ${TARGET_FULL} — gate fails"
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
