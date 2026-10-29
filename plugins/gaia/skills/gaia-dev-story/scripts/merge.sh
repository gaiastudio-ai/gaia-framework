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
#   merge.sh <pr_number> <story_key> [--strategy <merge|squash|rebase>] [--no-delete-branch]
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
#   GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE — operator-only bypass.
#       Format: <story_key>@<40-hex-head-sha>. Must be set by the operator
#       in their own shell. Model tool calls that set it are blocked by the
#       skill-scoped pre-tool guard. Confirmation at /dev/tty is required.
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
DELETE_BRANCH=false
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
# when the query itself is unavailable (network, auth, rate limit). Used
# after a merge failure to find out whether the merge actually happened.
remote_pr_state() {
  local pr="$1" extra="${2:-mergedAt}"
  gh pr view "$pr" --json "state,${extra}" --jq '.state' 2>/dev/null || echo "UNKNOWN"
}

# ---------------------------------------------------------------------------
# Single gh pr view call: read state, headRefName, headRefOid, baseRefName.
# Fail closed on query failure.
# ---------------------------------------------------------------------------
_pr_json="$(gh pr view "$PR_NUMBER" --json state,headRefName,headRefOid,baseRefName 2>/dev/null)" || _pr_json=""
if [ -z "$_pr_json" ]; then
  die "aborting: could not query PR #${PR_NUMBER}. Check that the PR exists, gh is authenticated, and the network is reachable."
fi

# Extract fields. Try jq first; fall back to grep for jq-absent environments.
_extract_field() {
  local json="$1" field="$2" val=""
  if command -v jq >/dev/null 2>&1; then
    val="$(printf '%s' "$json" | jq -r ".$field" 2>/dev/null)" || val=""
    [ "$val" = "null" ] && val=""
  fi
  if [ -z "$val" ]; then
    val="$(printf '%s' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)" || val=""
  fi
  printf '%s' "$val"
}

pr_state="$(_extract_field "$_pr_json" state)"
PR_HEAD_BRANCH="$(_extract_field "$_pr_json" headRefName)"
PR_HEAD_OID="$(_extract_field "$_pr_json" headRefOid)"
PR_TARGET="$(_extract_field "$_pr_json" baseRefName)"

# Idempotency check: is PR already merged? Fires before validation so
# a re-run on an already-merged PR exits cleanly regardless of metadata.
if [ "$pr_state" = "MERGED" ]; then
  log "PR #${PR_NUMBER} already merged — skipping"
  echo "already_merged"
  exit 0
fi

# Validate headRefOid: must be a 40-hex SHA. Refuse the merge otherwise
# (fail closed). An empty, null, or malformed OID means the API response
# was incomplete or the PR is in an unexpected state.
case "$PR_HEAD_OID" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    ;; # valid 40-hex SHA
  *)
    die "aborting: headRefOid '${PR_HEAD_OID}' from the API is not a valid 40-hex commit SHA. The PR metadata may be incomplete."
    ;;
esac

# Enforce security invariants BEFORE any gh pr merge call.
# All three hard gates run; YOLO mode does not bypass.

# Validate headRefName: reject empty, literal "null", and non-branch names.
if [ -z "$PR_HEAD_BRANCH" ] || [ "$PR_HEAD_BRANCH" = "null" ]; then
  die "aborting: could not determine PR head branch for #${PR_NUMBER}. Check that the PR exists, gh is authenticated, and the network is reachable."
fi
if ! git check-ref-format --branch "$PR_HEAD_BRANCH" >/dev/null 2>&1; then
  die "aborting: PR head branch name '${PR_HEAD_BRANCH}' is not a valid ref. The gh query may have returned an error."
fi
assert_branch_not_protected "$PR_HEAD_BRANCH" || die "aborting: protected-branch invariant failed"
assert_no_secrets_staged || die "aborting: staged-secrets invariant failed"

# Resolve PR target: fall back to "staging" when absent.
if [ -z "$PR_TARGET" ]; then
  PR_TARGET="staging"
fi
assert_pr_target_from_chain "$PR_TARGET" || die "aborting: pr-target invariant failed"

# ---------------------------------------------------------------------------
# Pre-merge Review Gate check.
#
# Calls review-gate-check.sh to verify the composite is COMPLETE (all rows
# PASSED and bound to the current head). Refuses the merge unless COMPLETE or
# the operator has explicitly bypassed the gate.
# ---------------------------------------------------------------------------

REVIEW_GATE_CHECK_SH="$SCRIPT_DIR/../../../scripts/review-gate-check.sh"

# _merge_locate_story — find the story markdown file for a given key.
# Searches under the shared project root's .gaia/artifacts/implementation-artifacts.
_merge_locate_story() {
  local key="$1"
  local root="${_MERGE_SHARED_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_ROOT:-}}}"
  local impl_dir=""
  if [ -n "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
    impl_dir="$IMPLEMENTATION_ARTIFACTS"
  elif [ -n "$root" ] && [ -d "$root/.gaia/artifacts/implementation-artifacts" ]; then
    impl_dir="$root/.gaia/artifacts/implementation-artifacts"
  elif [ -d "docs/implementation-artifacts" ]; then
    impl_dir="docs/implementation-artifacts"
  fi
  [ -z "$impl_dir" ] && return 1

  # Search: epic-*/<key>-*/story.md, <key>-*/story.md, <key>-*.md, epic-*/stories/<key>-*.md
  local found=""
  shopt -s nullglob
  local candidates=( "$impl_dir"/epic-*/"$key"-*/story.md "$impl_dir"/"$key"-*/story.md "$impl_dir"/"$key"-*.md "$impl_dir"/epic-*/stories/"$key"-*.md )
  shopt -u nullglob
  for f in "${candidates[@]}"; do
    [ -f "$f" ] || continue
    found="$f"
    break
  done
  [ -n "$found" ] && printf '%s' "$found" && return 0
  return 1
}

# Resolve the story file. In a GAIA project (story-artifact roots present),
# a missing story file fails the merge closed — the gate refuses rather than
# skip. In a non-GAIA repository (no story-artifact roots at all), the gate
# is skipped with a warning for backward compatibility.
_MERGE_STORY_FILE=""
_MERGE_STORY_FILE="$(_merge_locate_story "$STORY_KEY")" || _MERGE_STORY_FILE=""
_MERGE_GATE_ENABLED=1
if [ -z "$_MERGE_STORY_FILE" ] || [ ! -f "$_MERGE_STORY_FILE" ]; then
  # Detect whether this is a GAIA project by checking for story-artifact
  # roots. When any root exists, refusing is the safe default — a missing
  # file likely means misconfiguration or a renamed story.
  _merge_has_story_roots=0
  _merge_root_check="${_MERGE_SHARED_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_ROOT:-}}}"
  if [ -n "${IMPLEMENTATION_ARTIFACTS:-}" ] && [ -d "${IMPLEMENTATION_ARTIFACTS}" ]; then
    _merge_has_story_roots=1
  elif [ -n "$_merge_root_check" ] && [ -d "$_merge_root_check/.gaia/artifacts/implementation-artifacts" ]; then
    _merge_has_story_roots=1
  elif [ -d "docs/implementation-artifacts" ]; then
    _merge_has_story_roots=1
  fi
  if [ "$_merge_has_story_roots" -eq 1 ]; then
    die "aborting: cannot locate story file for '${STORY_KEY}' but story-artifact roots exist — refusing merge (fail closed). Check that the story file exists under implementation-artifacts and that CLAUDE_PROJECT_ROOT is set correctly."
  fi
  log "WARNING: cannot locate story file for '$STORY_KEY' and no story-artifact roots found — review gate check skipped (non-GAIA repository)"
  _MERGE_GATE_ENABLED=0
fi

# Determine the CI SHA to pass to review-gate-check.sh.
# When no CI is configured (no promotion chain), pass "none".
# Otherwise, pass the PR head SHA (the CI must have run on the head).
_merge_ci_sha="$PR_HEAD_OID"
_merge_cfg_for_ci="${_MERGE_SHARED_ROOT:+${_MERGE_SHARED_ROOT}/}.gaia/config/project-config.yaml"
if [ -n "${PROJECT_CONFIG:-}" ] && [ -f "${PROJECT_CONFIG}" ]; then
  _merge_cfg_for_ci="$PROJECT_CONFIG"
fi
_merge_has_promotion_chain=1
if [ -f "$_merge_cfg_for_ci" ] && command -v yq >/dev/null 2>&1; then
  _pc_val="$(yq '.ci_cd.promotion_chain' "$_merge_cfg_for_ci" 2>/dev/null)" || _pc_val=""
  case "$_pc_val" in
    "" | "null" | "~" | "[]") _merge_has_promotion_chain=0 ;;
  esac
fi
if [ "$_merge_has_promotion_chain" -eq 0 ]; then
  _merge_ci_sha="none"
fi

# Run review-gate-check.sh (only when the story file was found).
_rgc_rc=0
_rgc_output=""
if [ "$_MERGE_GATE_ENABLED" -eq 1 ]; then
  if [ -f "$REVIEW_GATE_CHECK_SH" ]; then
    _rgc_output="$(bash "$REVIEW_GATE_CHECK_SH" \
      --bind-head "$PR_HEAD_OID" \
      --ci-sha "$_merge_ci_sha" \
      --story "$_MERGE_STORY_FILE" 2>&1)" || _rgc_rc=$?
  else
    log "WARNING: review-gate-check.sh not found at $REVIEW_GATE_CHECK_SH — failing closed"
    _rgc_rc=1
    _rgc_output="Review Gate: BLOCKED (checker not found)"
  fi
fi

# If composite is COMPLETE (exit 0), proceed directly to the existing guards.
# If PENDING (exit 2) or BLOCKED (exit 1), check for operator bypass.
_MERGE_BYPASS_ACTIVE=0
_MERGE_BYPASS_NON_PASS_ROWS=""

if [ "$_MERGE_GATE_ENABLED" -eq 1 ] && [ "$_rgc_rc" -ne 0 ]; then
  # Extract non-PASS row information from the gate output.
  _MERGE_BYPASS_NON_PASS_ROWS="$(printf '%s' "$_rgc_output" | /usr/bin/grep -E '^  - ' || true)"

  # Determine gate status label for messaging.
  _gate_label="BLOCKED"
  [ "$_rgc_rc" -eq 2 ] && _gate_label="PENDING"

  # Check for operator bypass.
  _bypass_val="${GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE:-}"
  if [ -z "$_bypass_val" ]; then
    # No bypass set — refuse the merge.
    log "aborting: review gate composite is ${_gate_label} — merge refused"
    printf '%s\n' "$_rgc_output" >&2
    log "Set GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=${STORY_KEY}@${PR_HEAD_OID} to bypass (operator only)."
    exit 1
  fi

  # Validate bypass variable format: must be <story_key>@<40-hex-sha>.
  case "$_bypass_val" in
    *@*)
      _bypass_key="${_bypass_val%%@*}"
      _bypass_sha="${_bypass_val#*@}"
      ;;
    *)
      log "aborting: bypass variable format invalid — expected <story_key>@<40-hex-head-sha>"
      log "  current value: '${_bypass_val}'"
      log "  required: ${STORY_KEY}@${PR_HEAD_OID}"
      exit 1
      ;;
  esac

  # Validate the story key matches.
  if [ "$_bypass_key" != "$STORY_KEY" ]; then
    log "aborting: bypass key mismatch — variable has '${_bypass_key}', current story is '${STORY_KEY}'"
    log "  required: ${STORY_KEY}@${PR_HEAD_OID}"
    exit 1
  fi

  # Validate the SHA is exactly 40 hex characters.
  case "$_bypass_sha" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      ;; # valid 40-hex SHA
    *)
      log "aborting: bypass SHA must be exactly 40 hex characters"
      log "  got: '${_bypass_sha}' (${#_bypass_sha} chars)"
      log "  required: ${STORY_KEY}@${PR_HEAD_OID}"
      exit 1
      ;;
  esac

  # Validate the SHA matches the current PR head.
  if [ "$_bypass_sha" != "$PR_HEAD_OID" ]; then
    log "aborting: bypass SHA does not match the PR head"
    log "  bypass SHA: ${_bypass_sha}"
    log "  PR head:    ${PR_HEAD_OID}"
    log "  required: ${STORY_KEY}@${PR_HEAD_OID}"
    exit 1
  fi

  # Bypass variable is valid. Now require operator confirmation at the
  # controlling terminal.

  # Refuse under YOLO mode — the bypass is operator-interactive by design.
  if [ "${GAIA_YOLO_FLAG:-}" = "1" ] || [ "${GAIA_YOLO_FLAG:-}" = "true" ]; then
    log "aborting: review gate bypass cannot be confirmed under YOLO mode"
    log "  The operator must run this command in their own terminal:"
    log "  GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=${STORY_KEY}@${PR_HEAD_OID} bash merge.sh ${PR_NUMBER} ${STORY_KEY}"
    exit 1
  fi

  # Refuse inside the harness shell (the Claude agent environment).
  if [ "${GAIA_HARNESS_SHELL:-}" = "1" ] || [ "${GAIA_HARNESS_SHELL:-}" = "true" ]; then
    log "aborting: review gate bypass cannot be confirmed inside the harness shell"
    log "  The operator must run this command in their own terminal:"
    log "  GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=${STORY_KEY}@${PR_HEAD_OID} bash merge.sh ${PR_NUMBER} ${STORY_KEY}"
    exit 1
  fi

  # Resolve the tty read source for operator confirmation.
  # Production: /dev/tty (the operator's controlling terminal).
  # Test seam: _MERGE_TTY_OVERRIDE points to a regular file (containing
  # the answer) created by the test harness. This variable is blocked by
  # the pre-tool guard alongside the bypass variable — a model tool call
  # cannot set it. Prompt output always goes to /dev/tty (display only).
  _merge_tty_read="${_MERGE_TTY_OVERRIDE:-/dev/tty}"

  # Refuse when there is no controlling terminal and no test override.
  if [ ! -t 0 ] && [ ! -e "$_merge_tty_read" ]; then
    log "aborting: review gate bypass requires a controlling terminal (no /dev/tty)"
    log "  The operator must run this command in their own terminal:"
    log "  GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=${STORY_KEY}@${PR_HEAD_OID} bash merge.sh ${PR_NUMBER} ${STORY_KEY}"
    exit 1
  fi

  if [ -e "$_merge_tty_read" ]; then
    # Interactive confirmation: prompt at the terminal, read the answer.
    # Prompt output goes to /dev/tty when it is available and writable;
    # silently skipped otherwise (e.g., test contexts where /dev/tty exists
    # as a device node but is not configured for the subprocess).
    # The answer comes from the read source.
    {
      printf '\n=== Review Gate Bypass Confirmation ===\n'
      printf 'Story: %s\n' "$STORY_KEY"
      printf 'Head:  %s\n' "$PR_HEAD_OID"
      printf 'Gate:  %s\n' "$_gate_label"
      printf 'Non-PASS rows:\n'
      printf '%s\n' "$_MERGE_BYPASS_NON_PASS_ROWS"
      printf '\nType "yes" to bypass the review gate and merge: '
    } >/dev/tty 2>/dev/null || true
    read -r _bypass_answer <"$_merge_tty_read"
  else
    log "aborting: review gate bypass requires a controlling terminal"
    log "  The operator must run this command in their own terminal:"
    log "  GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=${STORY_KEY}@${PR_HEAD_OID} bash merge.sh ${PR_NUMBER} ${STORY_KEY}"
    exit 1
  fi

  if [ "$_bypass_answer" != "yes" ]; then
    log "aborting: operator declined the review gate bypass"
    exit 1
  fi

  _MERGE_BYPASS_ACTIVE=1
  log "review gate bypassed by operator (confirmed_by: operator_tty)"

  # The skill-scoped pre-tool guard (in merge-capable SKILL.md files) blocks
  # model tool calls that set this variable and writes a bypass_attempt_blocked
  # record to the sprint audit.

  # Record bypass in the story file.
  if [ -f "$_MERGE_STORY_FILE" ]; then
    {
      printf '\n<!-- review_gate_bypass: %s head=%s confirmed_by=operator_tty -->\n' \
        "$STORY_KEY" "$PR_HEAD_OID"
    } >> "$_MERGE_STORY_FILE"
  fi

  # Record bypass in the sprint audit.
  _audit_dir=""
  if [ -n "$_MERGE_SHARED_ROOT" ] && [ -d "$_MERGE_SHARED_ROOT/.gaia/state" ]; then
    _audit_dir="$_MERGE_SHARED_ROOT/.gaia/state/sprint-audit"
  elif [ -n "${CLAUDE_PROJECT_ROOT:-}" ] && [ -d "${CLAUDE_PROJECT_ROOT}/.gaia/state" ]; then
    _audit_dir="${CLAUDE_PROJECT_ROOT}/.gaia/state/sprint-audit"
  fi
  if [ -n "$_audit_dir" ]; then
    mkdir -p "$_audit_dir"
    cat > "$_audit_dir/review_gate_bypass-${STORY_KEY}.yaml" <<AUDIT
type: review_gate_bypass
story: ${STORY_KEY}
head: ${PR_HEAD_OID}
non_pass_rows:
$(printf '%s\n' "$_MERGE_BYPASS_NON_PASS_ROWS" | sed 's/^  - /  - "/; s/$/"/' | head -20)
confirmed_by: operator_tty
bypass_confirmed: true
timestamp: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
AUDIT
    log "bypass audit record written to $_audit_dir/review_gate_bypass-${STORY_KEY}.yaml"
  fi
fi

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

# Verify the fetched commit matches the headRefOid reported by the API.
# This catches fork PRs whose branch name collides with an origin branch
# and stale origin/<branch> refs from a narrow fetch refspec.
if [ "$PR_HEAD_COMMIT" != "$PR_HEAD_OID" ]; then
  log "aborting: fetched PR head commit ${PR_HEAD_COMMIT} does not match the API-reported headRefOid ${PR_HEAD_OID}."
  log "The local origin/${PR_HEAD_BRANCH} may be stale or point to a different commit than the PR. Run 'git fetch origin' and retry."
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

# ---------------------------------------------------------------------------
# Guard 4: merge_base_mismatch — re-read the PR base immediately before the
# merge call to detect retargeting between the gate check and the merge.
# ---------------------------------------------------------------------------
_pre_merge_json="$(gh pr view "$PR_NUMBER" --json baseRefName 2>/dev/null)" || _pre_merge_json=""
if [ -n "$_pre_merge_json" ]; then
  _pre_merge_base="$(_extract_field "$_pre_merge_json" baseRefName)"
  if [ -n "$_pre_merge_base" ] && [ "$_pre_merge_base" != "$PR_TARGET" ]; then
    log "aborting: merge_base_mismatch — PR base was '${PR_TARGET}' at gate check but is now '${_pre_merge_base}'"
    log "The PR was retargeted between the gate check and the merge call."
    exit 1
  fi
fi

# Build merge command. Always pass --match-head-commit so GitHub refuses
# the merge if the PR head moved since we checked it. Always pass
# --no-delete-branch — branch deletion moves to the worktree teardown.
MERGE_CMD="gh pr merge $PR_NUMBER --${STRATEGY} --body \"Story: ${STORY_KEY}\" --match-head-commit \"${PR_HEAD_OID}\" --no-delete-branch"
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
      head_branch="${PR_HEAD_BRANCH:-}"
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
    if [ "$_MERGE_BYPASS_ACTIVE" -eq 1 ]; then
      echo "merged:${STRATEGY}:bypass_confirmed=operator_tty"
    else
      echo "merged:${STRATEGY}"
    fi
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
if [ "$_MERGE_BYPASS_ACTIVE" -eq 1 ]; then
  echo "merged:${STRATEGY}:bypass_confirmed=operator_tty"
else
  echo "merged:${STRATEGY}"
fi
# Normal success path: verify inside L3 in concurrent mode.
if [ "$_MERGE_CONCURRENT" -eq 1 ]; then
  _merge_verify_in_l3 || exit 1
fi
exit 0
