#!/usr/bin/env bash
# merge.sh — gaia-dev-story PR merge
#
# Merges a PR after CI passes. Handles conflict detection, branch protection
# failures, and merge strategy selection from the promotion chain config.
#
# In concurrent mode (max_concurrent_active > 1 or per-sprint files exist),
# the merge is serialized via L3 (.gaia/state/.promotion-merge.lock) using
# strict-mode locking. Post-merge verification (git fetch + verify-pr-merged)
# runs inside the L3 critical section. In single-sprint mode, no lock is
# acquired and behavior is unchanged.
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
#   PROJECT_ROOT / CLAUDE_PROJECT_ROOT — optional. The shared project root
#                  for resolving L3 lock paths and config. When absent, the
#                  script walks up from $PWD to the first directory containing
#                  .gaia/state/.
#   GAIA_MERGE_LOCK_TIMEOUT — optional. L3 timeout in seconds (default 120).
#
# Exit codes:
#   0 — PR merged successfully (and verified in concurrent mode)
#   1 — merge failed (conflict, protection, verification, or other error)
#   3 — merge deferred (L3 timeout in concurrent mode)
#   4 — lock path is a symlink (strict-mode refusal)
#   5 — lock identity mismatch (strict-mode refusal)
#   7 — other lock failure (lock directory creation, generic refusal)

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

# Locking library. Used by the concurrent-mode promotion-merge lock (L3).
# Sourced unconditionally; no observable side effects for this script.
# shellcheck source=../../../scripts/lib/acquire-lock.sh
. "$SCRIPT_DIR/../../../scripts/lib/acquire-lock.sh"

# Non-git CWD guard: skip-with-warning when CWD is outside any git work tree.
# Runs BEFORE the security invariants so a non-git CWD never reaches the
# protected-branch / staged-secrets / pr-target checks.
# shellcheck source=../../../scripts/lib/non-git-cwd-guard.sh
. "$SCRIPT_DIR/../../../scripts/lib/non-git-cwd-guard.sh"

# ---------------------------------------------------------------------------
# Resolve the shared project root BEFORE cd to PROJECT_PATH (per R88).
# The promotion-merge lock, holder sidecar, per-sprint file probe, and config
# read all anchor at the shared root, never at PROJECT_PATH (which may be a
# story worktree holding its own .gaia/state decoy).
# ---------------------------------------------------------------------------
_MERGE_SHARED_ROOT=""
for _merge_candidate in "${PROJECT_ROOT:-}" "${CLAUDE_PROJECT_ROOT:-}"; do
  if [ -n "$_merge_candidate" ] && [ -d "$_merge_candidate/.gaia/state" ]; then
    _MERGE_SHARED_ROOT="$_merge_candidate"
    break
  fi
done
if [ -z "$_MERGE_SHARED_ROOT" ]; then
  _merge_walkup="$PWD"
  while [ "$_merge_walkup" != "/" ]; do
    if [ -d "$_merge_walkup/.gaia/state" ]; then
      _MERGE_SHARED_ROOT="$_merge_walkup"
      break
    fi
    _merge_walkup="$(dirname "$_merge_walkup")"
  done
  unset _merge_walkup
fi
unset _merge_candidate

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

# Idempotency check: is PR already merged? Fires BEFORE L3 acquisition and
# stays lock-free in both concurrent and single-sprint modes.
pr_state=$(remote_pr_state "$PR_NUMBER")
if [ "$pr_state" = "MERGED" ]; then
  log "PR #${PR_NUMBER} already merged — skipping"
  echo "already_merged"
  exit 0
fi

# Enforce security invariants BEFORE any gh pr merge call.
# All three hard gates run; YOLO mode does not bypass.

# Read the PR head branch from the GitHub API so the protected-branch guard
# checks the actual PR branch, not the local HEAD. After a story worktree
# teardown the local checkout is typically on staging (protected), but the
# PR head is the feature branch that should be merged. Fail closed: when
# the PR head cannot be determined (network, auth, missing PR), refuse the
# merge with an actionable message rather than falling back to local HEAD.
PR_HEAD_BRANCH="$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")"
if [ -z "$PR_HEAD_BRANCH" ]; then
  die "aborting: could not determine PR head branch for #${PR_NUMBER}. Check that the PR exists, gh is authenticated, and the network is reachable."
fi
# Validate: reject non-branch output (error text, "null", whitespace).
if ! git check-ref-format --branch "$PR_HEAD_BRANCH" >/dev/null 2>&1; then
  die "aborting: PR head branch name '${PR_HEAD_BRANCH}' is not a valid ref. The gh query may have returned an error or 'null'."
fi
assert_branch_not_protected "$PR_HEAD_BRANCH" || die "aborting: protected-branch invariant failed"
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
# blocks the merge. Fails closed: query errors, jq absence, and empty check
# lists all exit non-zero with an actionable message.
_gh_checks_err="$(mktemp "${TMPDIR:-/tmp}/merge-gh-checks.XXXXXX")"
checks_json="$(gh pr checks "$PR_NUMBER" --json bucket,name 2>"$_gh_checks_err")" || {
  log "aborting: could not query PR checks (gh pr checks failed)."
  log "  $(cat "$_gh_checks_err" 2>/dev/null)"
  log "Check network connectivity, authentication, and rate limits, then retry."
  rm -f "$_gh_checks_err"
  exit 1
}
rm -f "$_gh_checks_err"
# Parse checks: try jq first, fall back to grep-based parsing if jq is
# absent or fails.
check_count=""
bad_checks=""
if command -v jq >/dev/null 2>&1; then
  check_count="$(printf '%s' "$checks_json" | jq 'length' 2>/dev/null || true)"
  if [ -n "$check_count" ]; then
    bad_checks="$(printf '%s' "$checks_json" | jq -r '.[] | select(.bucket != "pass" and .bucket != "skipping") | .name' 2>/dev/null || true)"
  fi
fi
# Fallback: grep-based parsing when jq is absent or returned nothing.
if [ -z "$check_count" ]; then
  check_count="$(printf '%s' "$checks_json" | grep -c '"bucket"' 2>/dev/null)" || check_count="0"
  bad_checks="$(printf '%s' "$checks_json" \
    | grep -o '"bucket":"[^"]*","name":"[^"]*"' 2>/dev/null \
    | grep -v '"bucket":"pass"' \
    | grep -v '"bucket":"skipping"' \
    | sed 's/.*"name":"\([^"]*\)".*/\1/' 2>/dev/null || true)"
fi
# Validate check_count is a non-negative integer; fail closed otherwise.
case "$check_count" in
  ''|*[!0-9]*) check_count=0 ;;
esac
if [ "$check_count" -eq 0 ]; then
  log "aborting: no checks reported yet for PR #${PR_NUMBER}."
  log "Wait for CI to register checks and retry."
  exit 1
fi
if [ -n "$bad_checks" ]; then
  log "aborting: one or more PR checks have not passed:"
  printf '%s\n' "$bad_checks" | while IFS= read -r chk; do
    log "  - $chk"
  done
  log "Wait for pending checks to finish or fix failing ones, then retry."
  exit 1
fi

# Shared prerequisite for guards 2 and 3: fetch the base and the PR head.
# After worktree teardown, local HEAD is the primary checkout (staging),
# not the PR branch, so guards must compare against the fetched PR head
# commit rather than HEAD. Fail closed on fetch or resolve failure.
if ! git fetch origin "$PR_TARGET" --quiet 2>/dev/null; then
  log "aborting: 'git fetch origin ${PR_TARGET}' failed."
  log "Check network connectivity and that the remote branch exists, then retry."
  exit 1
fi
if ! git rev-parse --verify "origin/${PR_TARGET}" >/dev/null 2>&1; then
  log "aborting: cannot resolve origin/${PR_TARGET}."
  log "Run 'git fetch origin ${PR_TARGET}' and retry."
  exit 1
fi

# Fetch the PR head ref so guards 2 and 3 work after worktree teardown.
# Try the named branch first; fall back to the pull-request ref.
PR_HEAD_COMMIT=""
if git fetch origin "$PR_HEAD_BRANCH" --quiet 2>/dev/null; then
  PR_HEAD_COMMIT="$(git rev-parse --verify "origin/${PR_HEAD_BRANCH}" 2>/dev/null || echo "")"
fi
if [ -z "$PR_HEAD_COMMIT" ]; then
  if git fetch origin "pull/${PR_NUMBER}/head" --quiet 2>/dev/null; then
    PR_HEAD_COMMIT="$(git rev-parse FETCH_HEAD 2>/dev/null || echo "")"
  fi
fi
if [ -z "$PR_HEAD_COMMIT" ]; then
  log "aborting: could not fetch the PR head ref (tried origin/${PR_HEAD_BRANCH} and pull/${PR_NUMBER}/head)."
  log "Check network connectivity and that the PR branch exists on the remote, then retry."
  exit 1
fi

# Guard 2: the PR head must be based on the current base tip.
# Uses the fetched PR head commit, not local HEAD, so the guard works
# correctly after worktree teardown.
if ! git merge-base --is-ancestor "origin/${PR_TARGET}" "$PR_HEAD_COMMIT" 2>/dev/null; then
  head_short="$(git rev-parse --short "$PR_HEAD_COMMIT" 2>/dev/null || echo "$PR_HEAD_COMMIT")"
  log "aborting: PR head ${head_short} (${PR_HEAD_BRANCH}) is not based on origin/${PR_TARGET}."
  log "Run 'git rebase origin/${PR_TARGET}' or 'git merge origin/${PR_TARGET}' and push, then retry."
  exit 1
fi

# Guard 3: no commit in the PR range may carry an assistant attribution trailer.
# Scans origin/<base>..<pr_head_commit> — the PR's actual commits, not
# local HEAD (which is the primary checkout after teardown).
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

trailer_regex="$(_build_trailer_regex)"
# Fail closed: if the commit range cannot be enumerated, refuse the merge.
pr_commit_list="$(git log --format='%H' "origin/${PR_TARGET}..${PR_HEAD_COMMIT}" 2>/dev/null)" || pr_commit_list=""
if [ -z "$pr_commit_list" ]; then
  log "aborting: could not enumerate commits in origin/${PR_TARGET}..${PR_HEAD_COMMIT}."
  log "The PR range may be empty or unreachable. Fetch and retry."
  exit 1
fi
while IFS= read -r commit_hash; do
  [ -z "$commit_hash" ] && continue
  body="$(git log -1 --format='%B' "$commit_hash" 2>/dev/null || true)"
  matched="$(printf '%s\n' "$body" | grep -iE "^Co-Authored-By:.*($trailer_regex)" 2>/dev/null | head -1 || true)"
  if [ -n "$matched" ]; then
    short_hash="$(git rev-parse --short "$commit_hash" 2>/dev/null || echo "$commit_hash")"
    log "aborting: commit ${short_hash} carries an assistant attribution trailer:"
    log "  ${matched}"
    log "Strip it with 'git rebase -i' (edit the commit message) and force-push, then retry."
    exit 1
  fi
done <<< "$pr_commit_list"

# ---------------------------------------------------------------------------
# Concurrent-mode promotion-merge lock (L3).
#
# In concurrent mode (max_concurrent_active > 1 or per-sprint files exist),
# serialize merges via L3 to prevent simultaneous promotions from corrupting
# the promotion branch. In single-sprint mode, no lock is acquired.
# ---------------------------------------------------------------------------

_MERGE_CONCURRENT=0
_MERGE_L3_FD=200
_MERGE_L3_WRITER=0

# _merge_read_max_concurrent <config_file> — read sprint.max_concurrent_active
# from the project configuration. Returns the value on stdout; empty when the
# key is absent or unreadable.
_merge_read_max_concurrent() {
  local cfg="$1" val=""
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0
  if command -v yq >/dev/null 2>&1; then
    val="$(yq -r '.sprint.max_concurrent_active' "$cfg" 2>/dev/null)" || val=""
    [ "$val" = "null" ] && val=""
  fi
  if [ -z "$val" ]; then
    val="$(awk '/^sprint:/{s=1; next} s && /^[^ ]/{exit} s && /max_concurrent_active:/{sub(/.*max_concurrent_active:[[:space:]]*/,""); gsub(/[^0-9]/,""); print}' "$cfg" 2>/dev/null)" || val=""
  fi
  printf '%s' "$val"
}

# _merge_resolve_target_branch <config_file> — read the first promotion chain
# branch from project config. Empty when no promotion chain is configured.
_merge_resolve_target_branch() {
  local cfg="$1" branch=""
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0
  if command -v yq >/dev/null 2>&1; then
    branch="$(yq -r '.ci_cd.promotion_chain[0].branch' "$cfg" 2>/dev/null)" || branch=""
    [ "$branch" = "null" ] && branch=""
  fi
  if [ -z "$branch" ]; then
    branch="$(awk '
      /^[[:space:]]*promotion_chain:[[:space:]]*$/ { in_chain = 1; next }
      in_chain && /^[[:space:]]*-/ { in_item = 1 }
      in_chain && in_item && /branch:/ {
        sub(/.*branch:[[:space:]]*/, "")
        gsub(/"/, "")
        print
        exit
      }
      in_chain && /^[^[:space:]-]/ { exit }
    ' "$cfg" 2>/dev/null)" || branch=""
  fi
  printf '%s' "$branch"
}

# Determine concurrent mode. All state reads use the shared root (R88).
if [ -n "$_MERGE_SHARED_ROOT" ]; then
  _merge_cfg="${_MERGE_SHARED_ROOT}/.gaia/config/project-config.yaml"
  _merge_limit="$(_merge_read_max_concurrent "$_merge_cfg")"
  _merge_state_dir="${_MERGE_SHARED_ROOT}/.gaia/state"

  if acquire_lock_is_concurrent_mode "$_merge_limit" "$_merge_state_dir"; then
    _MERGE_CONCURRENT=1
  fi
  unset _merge_cfg _merge_limit _merge_state_dir
fi

# _merge_verify_in_l3 — run post-merge verification inside the L3 critical
# section. Resolves the target branch from config (falling back to the PR's
# baseRefName), fetches the remote ref, and runs verify-pr-merged.sh.
# Returns 0 on success; returns 1 on failure (the caller exits 1).
# Only called in concurrent mode.
_merge_verify_in_l3() {
  local target=""
  target="$(_merge_resolve_target_branch "${_MERGE_SHARED_ROOT}/.gaia/config/project-config.yaml")"
  [ -z "$target" ] && target="$PR_TARGET"

  if [ -n "$target" ]; then
    local fetch_rc=0
    git fetch origin "$target" --quiet 2>/dev/null || fetch_rc=$?
    if [ "$fetch_rc" -ne 0 ]; then
      log "WARNING: git fetch origin ${target} failed — merged but unverified"
      return 1
    fi
    local verify_rc=0
    "$SCRIPT_DIR/verify-pr-merged.sh" "$STORY_KEY" "origin/${target}" || verify_rc=$?
    case "$verify_rc" in
      0|3) return 0 ;; # pass or no-chain skip → merge exit 0
      *)
        log "WARNING: post-merge verification failed (exit ${verify_rc})"
        return 1
        ;;
    esac
  else
    # No target branch — call with --no-chain.
    # Exit 3 (no promotion chain) maps to merge exit 0.
    "$SCRIPT_DIR/verify-pr-merged.sh" "$STORY_KEY" --no-chain 2>/dev/null || true
    return 0
  fi
}

# Concurrent-mode trap and lock acquisition.
if [ "$_MERGE_CONCURRENT" -eq 1 ]; then
  _MERGE_L3_PATH="${_MERGE_SHARED_ROOT}/.gaia/state/${GAIA_LOCK_L3_PATH}"
  _MERGE_HOLDER_PATH="${_MERGE_SHARED_ROOT}/.gaia/state/.promotion-merge.holder"
  _MERGE_L3_TIMEOUT="${GAIA_MERGE_LOCK_TIMEOUT:-${GAIA_LOCK_L3_TIMEOUT}}"

  # Trap: release L3 and remove the holder sidecar (only when this process
  # wrote it) on every exit path. Covers EXIT, INT, TERM (no HUP, per R44).
  _merge_cleanup() {
    if [ "$_MERGE_L3_WRITER" -eq 1 ]; then
      local _holder_pid=""
      read -r _holder_pid _ < "$_MERGE_HOLDER_PATH" 2>/dev/null || _holder_pid=""
      if [ "$_holder_pid" = "$$" ]; then
        rm -f "$_MERGE_HOLDER_PATH" 2>/dev/null || true
      fi
    fi
    release_lock "$_MERGE_L3_FD" 2>/dev/null || true
  }
  trap _merge_cleanup EXIT INT TERM

  # Emit waiting message when holder sidecar exists before acquire.
  if [ -f "$_MERGE_HOLDER_PATH" ]; then
    log "waiting for promotion lock"
  fi

  # Acquire L3 (strict mode).
  _merge_acq_start="$(date +%s)"
  _merge_acq_rc=0
  acquire_lock "$_MERGE_L3_PATH" "$_MERGE_L3_TIMEOUT" "$_MERGE_L3_FD" --strict || _merge_acq_rc=$?

  case "$_merge_acq_rc" in
    0) ;; # Acquired successfully.
    "$ACQUIRE_LOCK_EXIT_TIMEOUT")
      # L3 timeout — merge deferred.
      _merge_elapsed="$(( $(date +%s) - _merge_acq_start ))"
      _merge_holder_pid="unknown"
      if [ -f "$_MERGE_HOLDER_PATH" ]; then
        read -r _hp _ < "$_MERGE_HOLDER_PATH" 2>/dev/null || _hp=""
        if [ -n "$_hp" ] && kill -0 "$_hp" 2>/dev/null; then
          _merge_holder_pid="$_hp"
        fi
      fi
      if [ "$_merge_holder_pid" = "unknown" ]; then
        if command -v lsof >/dev/null 2>&1; then
          _hp="$(lsof -t "$_MERGE_L3_PATH" 2>/dev/null | head -1)" || _hp=""
          [ -n "$_hp" ] && _merge_holder_pid="$_hp"
        elif command -v fuser >/dev/null 2>&1; then
          _hp="$(fuser "$_MERGE_L3_PATH" 2>/dev/null | tr -d ' ')" || _hp=""
          [ -n "$_hp" ] && _merge_holder_pid="$_hp"
        fi
      fi
      printf 'merge_deferred: %s after %ss (holder_pid=%s)\n' \
        "$_MERGE_L3_PATH" "$_merge_elapsed" "$_merge_holder_pid" >&2
      exit 3
      ;;
    "$ACQUIRE_LOCK_EXIT_SYMLINK")
      # Strict-mode: lock path is a symlink.
      exit 4
      ;;
    "$ACQUIRE_LOCK_EXIT_IDENTITY")
      # Strict-mode: identity mismatch after acquire.
      exit 5
      ;;
    *)
      # Generic lock failure.
      log "lock_failure: could not acquire promotion-merge lock (exit ${_merge_acq_rc})"
      exit 7
      ;;
  esac

  # Write holder sidecar.
  printf '%s %s\n' "$$" "$(date +%s)" > "$_MERGE_HOLDER_PATH" 2>/dev/null || true
  _MERGE_L3_WRITER=1
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
    # Recovery path: verify inside L3 in concurrent mode.
    if [ "$_MERGE_CONCURRENT" -eq 1 ]; then
      _merge_verify_in_l3 || exit 1
    fi
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
# Normal success path: verify inside L3 in concurrent mode.
if [ "$_MERGE_CONCURRENT" -eq 1 ]; then
  _merge_verify_in_l3 || exit 1
fi
exit 0
