#!/usr/bin/env bash
# merge.sh — gaia-dev-story PR merge
#
# Merges a PR after CI passes. Handles conflict detection, branch protection
# failures, and merge strategy selection from the promotion chain config.
#
# Never uses admin-override or any branch-protection bypass flag.
#
# Usage:
#   merge.sh <pr_number> <story_key> [--strategy <merge|squash|rebase>] [--delete-branch]
#
# Environment:
#   PROJECT_PATH — required. The git working directory. Resolved and entered
#                  BEFORE the non-git guard runs and before arguments are
#                  parsed, so relative path arguments resolve against it.
#
# Exit codes:
#   0 — PR merged successfully
#   1 — merge failed (conflict, protection, or other error)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/merge.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# Security invariants. Sourced from the canonical lib at
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
# Runs BEFORE the security invariants so a non-git CWD never reaches the
# protected-branch / staged-secrets / pr-target checks.
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
  die "usage: merge.sh <pr_number> <story_key> [--strategy <merge|squash|rebase>] [--delete-branch]"
fi

PR_NUMBER="$1"
STORY_KEY="$2"
shift 2

STRATEGY="squash"
DELETE_BRANCH=true
while [ $# -gt 0 ]; do
  case "$1" in
    --strategy)
      STRATEGY="$2"
      shift 2
      ;;
    --delete-branch)
      DELETE_BRANCH=true
      shift
      ;;
    --no-delete-branch)
      DELETE_BRANCH=false
      shift
      ;;
    *) die "unknown option: $1" ;;
  esac
done

# Validate strategy
case "$STRATEGY" in
  merge|squash|rebase) ;;
  *) die "Invalid merge_strategy '${STRATEGY}'. Allowed: merge, squash, rebase." ;;
esac


if ! command -v gh >/dev/null 2>&1; then
  die "Required tool gh not found. Install it or complete merge manually."
fi

# remote_pr_state <pr_number> [extra-json-field] — ask the remote for the
# pull request's authoritative state. Echoes the state verbatim, or UNKNOWN
# when the query itself is unavailable (network, auth, rate limit). Used at
# both ends of the merge call: once before it as an idempotency check, and
# once after a failure to find out whether the merge actually happened.
remote_pr_state() {
  local pr="$1" extra="${2:-mergedAt}"
  gh pr view "$pr" --json "state,${extra}" --jq '.state' 2>/dev/null || echo "UNKNOWN"
}

# Idempotency check: is PR already merged?
pr_state=$(remote_pr_state "$PR_NUMBER")
if [ "$pr_state" = "MERGED" ]; then
  log "PR #${PR_NUMBER} already merged — skipping"
  echo "already_merged"
  exit 0
fi

# Enforce security invariants BEFORE any gh pr merge call.
# All three hard gates run; YOLO mode does not bypass.
assert_branch_not_protected || die "aborting: protected-branch invariant failed"
assert_no_secrets_staged || die "aborting: staged-secrets invariant failed"

# Resolve PR target (baseRefName) from gh and verify against the canonical
# promotion chain. If gh fails to return a target, fall back to the
# project-config default ("staging") so the assertion still runs. Empty
# target propagates through assert_pr_target_from_chain as a clear failure.
PR_TARGET="$(gh pr view "$PR_NUMBER" --json baseRefName --jq '.baseRefName' 2>/dev/null || echo "")"
if [ -z "$PR_TARGET" ]; then
  PR_TARGET="staging"
fi
assert_pr_target_from_chain "$PR_TARGET" || die "aborting: pr-target invariant failed"

# ---------------------------------------------------------------------------
# Pre-merge guards (run AFTER security invariants, BEFORE gh pr merge).
# Guard order: (1) check state, (2) stale base, (3) attribution trailers.
# Each guard exits on the first failure it finds.
# ---------------------------------------------------------------------------

# Guard 1: every PR check must be pass or skipping.
# gh pr checks returns a JSON array of {bucket,name} objects. The accepted
# bucket values are "pass" and "skipping"; anything else (fail, pending, …)
# blocks the merge.
if command -v jq >/dev/null 2>&1; then
  checks_json="$(gh pr checks "$PR_NUMBER" --json bucket,name 2>/dev/null || echo "[]")"
  bad_checks="$(printf '%s' "$checks_json" | jq -r '.[] | select(.bucket != "pass" and .bucket != "skipping") | .name' 2>/dev/null || true)"
  if [ -n "$bad_checks" ]; then
    log "aborting: one or more PR checks have not passed:"
    printf '%s\n' "$bad_checks" | while IFS= read -r chk; do
      log "  - $chk"
    done
    log "Wait for pending checks to finish or fix failing ones, then retry."
    exit 1
  fi
fi

# Guard 2: the branch must be based on the current base tip.
# A stale base means the PR was opened against an older revision and needs a
# rebase before it can land cleanly. Requires origin/<base> to be resolvable;
# skipped when the remote ref cannot be fetched (e.g. no remote configured).
git fetch origin "$PR_TARGET" --quiet 2>/dev/null || true
if git rev-parse --verify "origin/${PR_TARGET}" >/dev/null 2>&1; then
  if ! git merge-base --is-ancestor "origin/${PR_TARGET}" HEAD 2>/dev/null; then
    head_ref="$(git rev-parse --short HEAD 2>/dev/null || echo "HEAD")"
    log "aborting: branch head ${head_ref} is not based on origin/${PR_TARGET}."
    log "Run 'git rebase origin/${PR_TARGET}' or 'git merge origin/${PR_TARGET}' and push, then retry."
    exit 1
  fi
fi

# Guard 3: no commit in the PR range may carry an assistant attribution trailer.
# Requires origin/<base> to be resolvable for the commit range; skipped when
# the remote ref cannot be resolved.
# Maintainable pattern list — extend by adding entries below.
ASSISTANT_TRAILER_PATTERNS=(
  "noreply@anthropic.com"
  "Claude"
  "GitHub Copilot"
  "copilot@github.com"
  "Anthropic"
)

_build_trailer_regex() {
  local pat result=""
  for pat in "${ASSISTANT_TRAILER_PATTERNS[@]}"; do
    if [ -n "$result" ]; then
      result="${result}|${pat}"
    else
      result="$pat"
    fi
  done
  printf '%s' "$result"
}

if git rev-parse --verify "origin/${PR_TARGET}" >/dev/null 2>&1; then
  trailer_regex="$(_build_trailer_regex)"
  # Scan every commit body in the PR range for Co-Authored-By trailers that
  # match the assistant pattern list.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    commit_hash="${line%%	*}"
    trailer_line="${line#*	}"
    short_hash="$(git rev-parse --short "$commit_hash" 2>/dev/null || echo "$commit_hash")"
    log "aborting: commit ${short_hash} carries an assistant attribution trailer:"
    log "  ${trailer_line}"
    log "Strip it with 'git rebase -i' (edit the commit message) and force-push, then retry."
    exit 1
  done < <(git log --format='%H %b' "origin/${PR_TARGET}..HEAD" 2>/dev/null \
    | grep -iE "^[0-9a-f]{40} " \
    | while IFS= read -r logline; do
        hash="${logline%% *}"
        body="${logline#* }"
        if printf '%s\n' "$body" | grep -iE "^Co-Authored-By:.*($trailer_regex)" >/dev/null 2>&1; then
          matched="$(printf '%s\n' "$body" | grep -iE "^Co-Authored-By:.*($trailer_regex)" | head -1)"
          printf '%s\t%s\n' "$hash" "$matched"
        fi
      done)
fi

# Build merge command
MERGE_CMD="gh pr merge $PR_NUMBER --${STRATEGY} --body \"Story: ${STORY_KEY}\""
if [ "$DELETE_BRANCH" = true ]; then
  MERGE_CMD="$MERGE_CMD --delete-branch"
fi

# Execute merge
merge_output=$(eval "$MERGE_CMD" 2>&1) || {
  # Classify failure
  if echo "$merge_output" | grep -qiE 'not mergeable|merge conflict|conflicts with base'; then
    log "Merge conflict detected. Resolve conflicts locally, push, and resume with /gaia-resume."
    exit 1
  fi

  if echo "$merge_output" | grep -qiE 'required status|required.*review|protected branch|review required'; then
    log "Branch protection blocked the merge. Unmet requirements:"
    printf '%s\n' "$merge_output" >&2
    log "Resolve protection requirements and retry."
    exit 1
  fi

  # The merge command performs the remote merge FIRST and only then attempts
  # a local branch switch. A purely local failure — most commonly the base
  # branch being checked out in another worktree — therefore exits non-zero
  # with the merge already done. Ask the remote which it was before calling
  # this a failure. Runs after the conflict and protection arms: both of
  # those describe a genuinely unmerged pull request and are more specific.
  post_state="$(remote_pr_state "$PR_NUMBER" mergeCommit)"
  if [ "$post_state" = "MERGED" ]; then
    log "WARNING: the merge command failed locally but the remote reports the pull request as merged."
    log "WARNING: local failure was: $merge_output"
    if [ "$DELETE_BRANCH" = true ]; then
      # The merge command aborted before its own branch-deletion step, so
      # finish the cleanup it skipped. An already-absent branch is success.
      head_branch="$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")"
      if [ -n "$head_branch" ]; then
        repo_slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"
        if [ -n "$repo_slug" ]; then
          delete_path="repos/${repo_slug}/git/refs/heads/${head_branch}"
        else
          delete_path="repos/{owner}/{repo}/git/refs/heads/${head_branch}"
        fi
        if gh api -X DELETE "$delete_path" >/dev/null 2>&1; then
          log "Deleted merged head branch '${head_branch}' (cleanup skipped by the merge command)."
        else
          log "WARNING: could not delete head branch '${head_branch}' — it may already be gone."
        fi
      else
        log "WARNING: could not resolve the head branch; skipping branch cleanup."
      fi
    fi
    log "PR #${PR_NUMBER} merged via ${STRATEGY}"
    echo "merged:${STRATEGY}"
    exit 0
  fi

  # Remote confirmation was unavailable or says the pull request is not
  # merged. If the wording points at a worktree branch-checkout conflict,
  # name that cause instead of the generic line.
  if echo "$merge_output" | grep -qi 'already used by worktree'; then
    log "The merge command could not switch the local checkout: the base branch is already checked out in another worktree."
    log "The remote merge may well have succeeded — confirm the pull request state manually before retrying."
    printf '%s\n' "$merge_output" >&2
    exit 1
  fi

  log "Merge failed: $merge_output"
  log "Resume with /gaia-resume after resolving."
  exit 1
}

log "PR #${PR_NUMBER} merged via ${STRATEGY}"
echo "merged:${STRATEGY}"
exit 0
