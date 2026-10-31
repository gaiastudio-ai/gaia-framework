#!/usr/bin/env bash
# merge-tail.sh — resumable verb-driven merge tail.
#
# Drives the five-verb merge sequence: gate, merge, verify, smoke-wait,
# finalize.  Each verb is idempotent against the merge ledger.  Session
# kills between any pair of verbs are recoverable: the ledger state machine
# is the source of truth for resumption.
#
# Usage:
#   merge-tail.sh <verb> --story <key> --pr <n> --head <sha> --target <branch>
#                        [--mode <story|integration|promotion>]
#                        [--merge-strategy <merge|squash|rebase>]
#                        [--bypass-confirmation <result>]
#
# Verbs:
#   gate        — record a gate_pass or gate_bypass in the ledger
#   merge       — create a merge intent and execute the merge
#   verify      — verify the merge target matches the ledger's target
#   smoke-wait  — run or skip post-merge smoke test
#   finalize    — advance the intent to finalized
#
# Environment:
#   CLAUDE_PROJECT_ROOT / PROJECT_ROOT — shared project root.
#   PROJECT_PATH — git working directory.
#   PROJECT_CONFIG — explicit config path.
#   MERGE_LEDGER_DIR — override ledger directory (testing).
#   MERGE_TAIL_SMOKE_CMD — configured smoke command (testing override).
#   MERGE_TAIL_SKIP_MERGE — when "1", skip the actual gh pr merge (testing).
#   MERGE_TAIL_MOCK_PR_STATE — mock PR state for testing (MERGED|OPEN).
#   MERGE_TAIL_MOCK_PR_BASE — mock PR base branch for testing.
#   MERGE_LEDGER_SKIP_GH — when "1", skip gh calls in ledger (testing).
#
# Exit codes:
#   0 — verb completed successfully
#   1 — error (gate failure, merge failure, verification failure, etc.)
#
# Per-call bound: each verb returns within 540 seconds.
#
# Bash 3.2 compatible.

set -euo pipefail
LC_ALL=C; export LC_ALL

_MT_SCRIPT_NAME="merge-tail.sh"
_MT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MT_MAX_SECONDS="${MERGE_TAIL_MAX_SECONDS:-540}"
_MT_START_SECONDS="$SECONDS"

_mt_log() { printf '%s: %s\n' "$_MT_SCRIPT_NAME" "$*" >&2; }
_mt_die() { _mt_log "$*"; exit 1; }

# --- Ceiling validation for MERGE_TAIL_MAX_SECONDS ---
case "$_MT_MAX_SECONDS" in
  *[!0-9]*)
    _mt_die "MERGE_TAIL_MAX_SECONDS must be a non-negative integer, got: '${_MT_MAX_SECONDS}'"
    ;;
esac
if [ "$_MT_MAX_SECONDS" -gt 540 ]; then
  _mt_log "clamping MERGE_TAIL_MAX_SECONDS from ${_MT_MAX_SECONDS} to 540"
  _MT_MAX_SECONDS=540
fi

# --- Preemptive bound helpers ---

# _mt_check_bound — fail if the per-call bound has been exceeded.
_mt_check_bound() {
  local elapsed=$(( SECONDS - _MT_START_SECONDS ))
  if [ "$elapsed" -ge "$_MT_MAX_SECONDS" ]; then
    _mt_die "per-call bound exceeded (${elapsed}s >= ${_MT_MAX_SECONDS}s)"
  fi
}

# _mt_remaining — seconds left in the per-call bound.
_mt_remaining() {
  local elapsed=$(( SECONDS - _MT_START_SECONDS ))
  local remaining=$(( _MT_MAX_SECONDS - elapsed ))
  [ "$remaining" -lt 0 ] && remaining=0
  printf '%s' "$remaining"
}

# _mt_bounded <command> [args...] — run command within the remaining bound.
# Returns 142 via _mt_die if the bound fires; otherwise the command's exit
# code (which set -e propagates on non-zero).
_mt_bounded() {
  local _rc=0
  bound_exec "$(_mt_remaining)" -- "$@" || _rc=$?
  if [ "$_rc" -eq 142 ]; then
    _mt_die "per-call bound exceeded (${_MT_MAX_SECONDS}s)"
  fi
  return "$_rc"
}

# Resolve bound-exec library (preemptive subprocess bounding)
_MT_BOUND_EXEC_LIB="${_MT_SCRIPT_DIR}/lib/bound-exec.sh"
[ -f "$_MT_BOUND_EXEC_LIB" ] || _mt_die "bound-exec.sh not found at $_MT_BOUND_EXEC_LIB"
# shellcheck source=lib/bound-exec.sh
. "$_MT_BOUND_EXEC_LIB"

# Resolve merge-ledger.sh
_MT_LEDGER_SH="${_MT_SCRIPT_DIR}/merge-ledger.sh"
[ -f "$_MT_LEDGER_SH" ] || _mt_die "merge-ledger.sh not found at $_MT_LEDGER_SH"

# --- Argument parsing ---
_mt_verb=""
_mt_story=""
_mt_pr=""
_mt_head=""
_mt_target=""
_mt_mode="story"
_mt_merge_strategy="squash"
_mt_bypass_confirmation=""

if [ $# -lt 1 ]; then
  _mt_die "usage: merge-tail.sh <verb> --story <key> --pr <n> --head <sha> --target <branch>"
fi

_mt_verb="$1"
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --story)                _mt_story="$2"; shift 2 ;;
    --pr)                   _mt_pr="$2"; shift 2 ;;
    --head)                 _mt_head="$2"; shift 2 ;;
    --target)               _mt_target="$2"; shift 2 ;;
    --mode)                 _mt_mode="$2"; shift 2 ;;
    --merge-strategy)       _mt_merge_strategy="$2"; shift 2 ;;
    --bypass-confirmation)  _mt_bypass_confirmation="$2"; shift 2 ;;
    *) _mt_die "unknown option: $1" ;;
  esac
done

[ -z "$_mt_story" ] && _mt_die "--story required"
[ -z "$_mt_pr" ] && _mt_die "--pr required"
[ -z "$_mt_head" ] && _mt_die "--head required"
[ -z "$_mt_target" ] && _mt_die "--target required"

# --- Session-kill resilience helpers ---

# _mt_check_resume — check the ledger for an existing intent and determine
# what to do.  Returns: "resume:<state>" if we can resume, or "new" if we
# need a fresh intent, or "superseded" if the head moved.
_mt_check_resume() {
  local intent_output=""
  intent_output="$(bash "$_MT_LEDGER_SH" read-latest --pr "$_mt_pr" 2>/dev/null)" || intent_output=""

  if [ -z "$intent_output" ]; then
    printf 'new'
    return 0
  fi

  local intent_state="" intent_head=""
  intent_state="$(printf '%s' "$intent_output" | sed -n 's/^state: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -1)"
  intent_head="$(printf '%s' "$intent_output" | sed -n 's/^head_sha: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -1)"

  # Terminal intents are done — allow a fresh start regardless of head
  case "$intent_state" in
    superseded|finalized)
      printf 'new'
      return 0
      ;;
  esac

  if [ "$intent_head" != "$_mt_head" ]; then
    printf 'superseded'
    return 0
  fi

  printf 'resume:%s' "$intent_state"
}

# --- Verb: gate ---
_mt_verb_gate() {
  _mt_check_bound
  if [ -n "$_mt_bypass_confirmation" ]; then
    _mt_bounded bash "$_MT_LEDGER_SH" write-gate-bypass \
      --pr "$_mt_pr" --head "$_mt_head" --story "$_mt_story" \
      --bypass-confirmation "$_mt_bypass_confirmation"
  else
    _mt_bounded bash "$_MT_LEDGER_SH" write-gate-pass \
      --pr "$_mt_pr" --head "$_mt_head" --story "$_mt_story"
  fi
}

# --- Verb: merge ---
_mt_verb_merge() {
  _mt_check_bound
  # Check for session-kill resilience
  local resume=""
  resume="$(_mt_check_resume)"

  case "$resume" in
    superseded)
      # Close the old intent (read its head first) and tell the caller to
      # re-run the gate with the new head.
      _mt_log "head moved: superseding old intent"
      local _old_intent=""
      _old_intent="$(bash "$_MT_LEDGER_SH" read-latest --pr "$_mt_pr" 2>/dev/null)" || _old_intent=""
      local _old_head=""
      _old_head="$(printf '%s' "$_old_intent" | sed -n 's/^head_sha: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -1)"
      if [ -n "$_old_head" ]; then
        bash "$_MT_LEDGER_SH" supersede --pr "$_mt_pr" --head "$_old_head" 2>/dev/null || true
      fi
      _mt_die "head moved: old intent superseded — re-run gate with the new head"
      ;;
    resume:intent)
      _mt_log "resuming from intent state"
      ;;
    resume:merging)
      _mt_log "resuming from merging state — checking PR status"
      # Check if the PR was actually merged
      local pr_state=""
      if [ "${MERGE_TAIL_MOCK_PR_STATE:-}" ]; then
        pr_state="$MERGE_TAIL_MOCK_PR_STATE"
      elif command -v gh >/dev/null 2>&1; then
        local _pr_rc=0
        pr_state="$(bound_exec "$(_mt_remaining)" -- gh pr view "$_mt_pr" --json state --jq '.state' 2>/dev/null)" || _pr_rc=$?
        [ "$_pr_rc" -eq 142 ] && _mt_die "per-call bound exceeded during PR state check"
        [ "$_pr_rc" -ne 0 ] && pr_state="UNKNOWN"
      else
        pr_state="UNKNOWN"
      fi

      if [ "$pr_state" = "MERGED" ]; then
        _mt_log "PR #${_mt_pr} already merged — advancing to merged"
        bash "$_MT_LEDGER_SH" advance --pr "$_mt_pr" --head "$_mt_head" --state merged
        return 0
      fi
      # Not merged yet — fall through to merge
      ;;
    resume:merged|resume:verified|resume:smoke_ok|resume:smoke_failed|resume:finalized)
      _mt_log "intent already past merge (state: ${resume#resume:})"
      return 0
      ;;
    new)
      ;;
  esac

  # Create the merge intent (write-ahead)
  bash "$_MT_LEDGER_SH" write-intent \
    --pr "$_mt_pr" --head "$_mt_head" --story "$_mt_story" \
    --target "$_mt_target" --mode "$_mt_mode"

  # Advance to merging
  bash "$_MT_LEDGER_SH" advance --pr "$_mt_pr" --head "$_mt_head" --state merging

  # Execute the merge (unless testing)
  if [ "${MERGE_TAIL_SKIP_MERGE:-}" = "1" ]; then
    _mt_log "merge skipped (test mode)"
    bash "$_MT_LEDGER_SH" advance --pr "$_mt_pr" --head "$_mt_head" --state merged
    return 0
  fi

  local merge_rc=0
  if command -v gh >/dev/null 2>&1; then
    bound_exec "$(_mt_remaining)" -- \
      gh pr merge "$_mt_pr" "--${_mt_merge_strategy}" \
      --body "Story: ${_mt_story}" \
      --match-head-commit "$_mt_head" \
      --no-delete-branch 2>&1 || merge_rc=$?
  else
    _mt_die "gh not available — cannot merge"
  fi

  if [ "$merge_rc" -eq 142 ]; then
    _mt_die "per-call bound exceeded during merge"
  fi
  if [ "$merge_rc" -ne 0 ]; then
    _mt_die "merge failed for PR #${_mt_pr} (exit ${merge_rc})"
  fi

  # Get the merge SHA (bounded)
  local merge_sha="" _sha_rc=0
  if command -v gh >/dev/null 2>&1; then
    merge_sha="$(bound_exec "$(_mt_remaining)" -- gh pr view "$_mt_pr" --json mergeCommit --jq '.mergeCommit.oid' 2>/dev/null)" || _sha_rc=$?
    [ "$_sha_rc" -eq 142 ] && _mt_die "per-call bound exceeded during merge SHA retrieval"
    [ "$_sha_rc" -ne 0 ] && merge_sha=""
  fi

  bash "$_MT_LEDGER_SH" advance --pr "$_mt_pr" --head "$_mt_head" --state merged \
    ${merge_sha:+--merge-sha "$merge_sha"}
}

# --- Verb: verify ---
_mt_verb_verify() {
  _mt_check_bound
  # Check for session-kill resilience
  local resume=""
  resume="$(_mt_check_resume)"

  case "$resume" in
    resume:merged)
      _mt_log "verifying merge target"
      ;;
    resume:intent|resume:merging)
      _mt_die "verify called but intent is in state ${resume#resume:} — merge has not completed"
      ;;
    resume:verified|resume:smoke_ok|resume:smoke_failed|resume:finalized)
      _mt_log "already past verify (state: ${resume#resume:})"
      return 0
      ;;
    new)
      _mt_die "verify called but no intent found for PR #${_mt_pr}"
      ;;
    superseded)
      _mt_die "verify called but head has moved — intent superseded"
      ;;
  esac

  # Read the ledger's target
  local intent_output=""
  intent_output="$(bash "$_MT_LEDGER_SH" read-latest --pr "$_mt_pr" --head "$_mt_head" 2>/dev/null)" || intent_output=""
  local ledger_target=""
  ledger_target="$(printf '%s' "$intent_output" | sed -n 's/^target: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -1)"

  # Get the actual merged target from the PR (bounded)
  local actual_target=""
  if [ "${MERGE_TAIL_MOCK_PR_BASE:-}" ]; then
    actual_target="$MERGE_TAIL_MOCK_PR_BASE"
  elif command -v gh >/dev/null 2>&1; then
    local _at_rc=0
    actual_target="$(bound_exec "$(_mt_remaining)" -- gh pr view "$_mt_pr" --json baseRefName --jq '.baseRefName' 2>/dev/null)" || _at_rc=$?
    [ "$_at_rc" -eq 142 ] && _mt_die "per-call bound exceeded during verify"
    [ "$_at_rc" -ne 0 ] && actual_target=""
  fi

  if [ -n "$ledger_target" ] && [ -n "$actual_target" ] && [ "$ledger_target" != "$actual_target" ]; then
    _mt_log "merge_target_mismatch: ledger target '${ledger_target}' != actual target '${actual_target}'"
    printf 'merge_target_mismatch\n'
    exit 1
  fi

  bash "$_MT_LEDGER_SH" advance --pr "$_mt_pr" --head "$_mt_head" --state verified
  _mt_log "merge target verified"
}

# --- Verb: smoke-wait ---
_mt_verb_smoke_wait() {
  _mt_check_bound
  # Check for session-kill resilience
  local resume=""
  resume="$(_mt_check_resume)"

  case "$resume" in
    resume:verified)
      _mt_log "running smoke-wait"
      ;;
    resume:smoke_ok|resume:smoke_failed|resume:finalized)
      _mt_log "already past smoke-wait (state: ${resume#resume:})"
      return 0
      ;;
    resume:intent|resume:merging|resume:merged)
      _mt_die "smoke-wait called but intent is in state ${resume#resume:} — verify has not completed"
      ;;
    new)
      _mt_die "smoke-wait called but no intent found"
      ;;
    superseded)
      _mt_die "smoke-wait called but head has moved — intent superseded"
      ;;
  esac

  # Determine smoke source
  local smoke_cmd="${MERGE_TAIL_SMOKE_CMD:-}"

  # Check config for smoke command if not set
  if [ -z "$smoke_cmd" ]; then
    local cfg=""
    cfg="$(_mt_resolve_config 2>/dev/null)" || cfg=""
    if [ -n "$cfg" ] && [ -f "$cfg" ] && command -v yq >/dev/null 2>&1; then
      smoke_cmd="$(yq -r '.ci_cd.smoke_command // empty' "$cfg" 2>/dev/null)" || smoke_cmd=""
      [ "$smoke_cmd" = "null" ] && smoke_cmd=""
    fi
  fi

  if [ -z "$smoke_cmd" ]; then
    # No smoke command — check if CI has a push trigger on target
    # For now, skip with notice
    _mt_log "smoke-wait: skipped — no smoke command configured"
    _mt_log "To enable: set ci_cd.smoke_command in project-config.yaml"
    bash "$_MT_LEDGER_SH" advance --pr "$_mt_pr" --head "$_mt_head" --state smoke_ok
    return 0
  fi

  # Run smoke command through parent-exec.
  # The smoke runner is launched through parent-exec (sanitized env) with
  # detach for process-group isolation.  The runner writes its exit code
  # to a result file so the caller can detect failure after the detached
  # process completes.
  local parent_exec_lib="${_MT_SCRIPT_DIR}/lib/parent-exec.sh"
  local smoke_rc=0
  local smoke_result_file="${MERGE_LEDGER_DIR:-.}/smoke-result-$$"

  if [ -f "$parent_exec_lib" ]; then
    # shellcheck source=lib/parent-exec.sh
    . "$parent_exec_lib"
    # Run the smoke command and capture its exit code.  The detach library
    # launches the runner in a new process group; we wait for the result
    # file to appear.
    local smoke_wrapper
    smoke_wrapper="$(printf 'sh -c %s; echo $? > %s' "'${smoke_cmd}'" "'${smoke_result_file}'")"
    parent_exec_run -- sh -c "$smoke_wrapper" || smoke_rc=$?
    if [ -f "$smoke_result_file" ]; then
      smoke_rc="$(cat "$smoke_result_file")"
      rm -f "$smoke_result_file"
    fi
  else
    _mt_log "WARNING: parent-exec.sh not found — running smoke directly"
    sh -c "$smoke_cmd" || smoke_rc=$?
  fi

  if [ "$smoke_rc" -ne 0 ]; then
    _mt_log "smoke test failed (exit ${smoke_rc})"
    bash "$_MT_LEDGER_SH" advance --pr "$_mt_pr" --head "$_mt_head" --state smoke_failed
    # Write a findings row (to stdout for the caller to capture)
    printf 'merged-smoke-failed: smoke command exited %d\n' "$smoke_rc"
    exit 1
  fi

  bash "$_MT_LEDGER_SH" advance --pr "$_mt_pr" --head "$_mt_head" --state smoke_ok
  _mt_log "smoke test passed"
}

# --- Verb: finalize ---
_mt_verb_finalize() {
  _mt_check_bound
  # Check for session-kill resilience
  local resume=""
  resume="$(_mt_check_resume)"

  case "$resume" in
    resume:smoke_ok|resume:smoke_failed)
      _mt_log "finalizing"
      ;;
    resume:finalized)
      _mt_log "already finalized"
      return 0
      ;;
    resume:intent|resume:merging|resume:merged|resume:verified)
      _mt_die "finalize called but intent is in state ${resume#resume:} — smoke-wait has not completed"
      ;;
    new)
      _mt_die "finalize called but no intent found"
      ;;
    superseded)
      _mt_die "finalize called but head has moved — intent superseded"
      ;;
  esac

  bash "$_MT_LEDGER_SH" advance --pr "$_mt_pr" --head "$_mt_head" --state finalized
  _mt_log "merge finalized for story ${_mt_story}"
}

# --- Config resolution (shared with smoke-wait) ---
_mt_resolve_config() {
  if [ -n "${PROJECT_CONFIG:-}" ] && [ -f "${PROJECT_CONFIG}" ]; then
    printf '%s' "$PROJECT_CONFIG"
    return 0
  fi
  local root=""
  for _c in "${CLAUDE_PROJECT_ROOT:-}" "${PROJECT_ROOT:-}"; do
    if [ -n "$_c" ] && [ -f "$_c/.gaia/config/project-config.yaml" ]; then
      root="$_c"
      break
    fi
  done
  [ -n "$root" ] && printf '%s' "$root/.gaia/config/project-config.yaml" && return 0
  return 1
}

# --- Dispatch ---
case "$_mt_verb" in
  gate)       _mt_verb_gate ;;
  merge)      _mt_verb_merge ;;
  verify)     _mt_verb_verify ;;
  smoke-wait) _mt_verb_smoke_wait ;;
  finalize)   _mt_verb_finalize ;;
  *) _mt_die "unknown verb: $_mt_verb" ;;
esac
