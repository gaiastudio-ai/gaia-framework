#!/usr/bin/env bash
# ci-wait-ref.sh — commit-level CI waiter with deadline resume.
#
# Polls check runs on a specific commit SHA.  Returns green|red|pending|
# none-observed.  Only check runs from configured workflows count;
# bare commit statuses count only when their context is declared in
# ci_cd.ci_status_contexts (default empty).
#
# The CI-wait deadline is stored on the merge-ledger intent record so it
# can resume across sessions without restarting the clock.
#
# Usage:
#   ci-wait-ref.sh --sha <sha> [--branch <b>] --max-seconds <N>
#
# Environment:
#   CLAUDE_PROJECT_ROOT / PROJECT_ROOT — for config and ledger resolution.
#   PROJECT_CONFIG — explicit path to project-config.yaml.
#   CI_WAIT_REF_POLL_INTERVAL — poll cadence in seconds (default 15).
#   CI_WAIT_REF_WORKFLOWS — override configured workflow names
#     (comma-separated; for testing).
#   CI_WAIT_REF_STATUS_CONTEXTS — override ci_cd.ci_status_contexts
#     (comma-separated; for testing).
#   CI_WAIT_REF_SKIP_GH — when "1", skip gh calls and return
#     none-observed (testing without gh).
#   MERGE_LEDGER_DIR — override for ledger directory (testing).
#
# Exit codes:
#   0 — green (all configured checks passed)
#   1 — red (at least one check failed)
#   2 — pending (timeout reached with checks still running)
#   3 — none-observed (no check runs found)
#
# Bash 3.2 compatible.

set -euo pipefail
LC_ALL=C; export LC_ALL

_CWR_SCRIPT_NAME="ci-wait-ref.sh"
_CWR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_cwr_log() { printf '%s: %s\n' "$_CWR_SCRIPT_NAME" "$*" >&2; }
_cwr_die() { _cwr_log "$*"; exit 1; }

# Source bound-exec for preemptive subprocess bounding
_CWR_BOUND_EXEC_LIB="${_CWR_SCRIPT_DIR}/lib/bound-exec.sh"
[ -f "$_CWR_BOUND_EXEC_LIB" ] || _cwr_die "bound-exec.sh not found at $_CWR_BOUND_EXEC_LIB"
# shellcheck source=lib/bound-exec.sh
. "$_CWR_BOUND_EXEC_LIB"

# --- Argument parsing ---
_cwr_sha=""
_cwr_branch=""
_cwr_max_seconds=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sha)         _cwr_sha="$2"; shift 2 ;;
    --branch)      _cwr_branch="$2"; shift 2 ;;
    --max-seconds) _cwr_max_seconds="$2"; shift 2 ;;
    *) _cwr_die "unknown option: $1" ;;
  esac
done

[ -z "$_cwr_sha" ] && _cwr_die "--sha required"
[ -z "$_cwr_max_seconds" ] && _cwr_die "--max-seconds required"

# Validate max-seconds is a positive integer <= 540
case "$_cwr_max_seconds" in
  ''|*[!0-9]*) _cwr_die "--max-seconds must be a positive integer, got: '$_cwr_max_seconds'" ;;
esac
if [ "$_cwr_max_seconds" -gt 540 ]; then
  _cwr_die "--max-seconds must not exceed 540, got: $_cwr_max_seconds"
fi

# --- Config resolution ---
_cwr_resolve_config() {
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
  if [ -z "$root" ]; then
    local _w="$PWD"
    while [ "$_w" != "/" ]; do
      if [ -f "$_w/.gaia/config/project-config.yaml" ]; then
        root="$_w"
        break
      fi
      _w="$(dirname "$_w")"
    done
  fi
  [ -n "$root" ] && printf '%s' "$root/.gaia/config/project-config.yaml" && return 0
  return 1
}

# _cwr_read_configured_workflows — read ci_cd workflow names from config.
_cwr_read_configured_workflows() {
  if [ -n "${CI_WAIT_REF_WORKFLOWS:-}" ]; then
    printf '%s' "$CI_WAIT_REF_WORKFLOWS" | tr ',' '\n'
    return 0
  fi
  local cfg=""
  cfg="$(_cwr_resolve_config 2>/dev/null)" || cfg=""
  if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then return 1; fi

  if command -v yq >/dev/null 2>&1; then
    yq -r '.ci_cd.workflows[]?.name // empty' "$cfg" 2>/dev/null || true
  fi
}

# _cwr_read_status_contexts — read ci_cd.ci_status_contexts from config.
_cwr_read_status_contexts() {
  if [ -n "${CI_WAIT_REF_STATUS_CONTEXTS:-}" ]; then
    printf '%s' "$CI_WAIT_REF_STATUS_CONTEXTS" | tr ',' '\n'
    return 0
  fi
  local cfg=""
  cfg="$(_cwr_resolve_config 2>/dev/null)" || cfg=""
  if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then return 0; fi

  if command -v yq >/dev/null 2>&1; then
    yq -r '.ci_cd.ci_status_contexts[]? // empty' "$cfg" 2>/dev/null || true
  fi
}

# --- Deadline resume ---
# Try to read the CI-wait start time from the ledger intent record.
_cwr_read_deadline_start() {
  local ledger_sh=""
  ledger_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-ledger.sh"
  if [ ! -f "$ledger_sh" ]; then return 1; fi

  # Find the latest intent for this SHA
  local pr="${_cwr_branch:-}"
  if [ -z "$pr" ]; then return 1; fi

  local intent_output=""
  intent_output="$(bash "$ledger_sh" read-latest --pr "$pr" 2>/dev/null)" || return 1
  local ci_start=""
  ci_start="$(printf '%s' "$intent_output" | sed -n 's/^ci_wait_started: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -1)"
  if [ -n "$ci_start" ]; then
    # Convert ISO timestamp to epoch seconds
    if date -d "$ci_start" +%s 2>/dev/null; then
      return 0
    elif date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ci_start" +%s 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# --- Polling ---
_cwr_poll_interval="${CI_WAIT_REF_POLL_INTERVAL:-15}"
case "$_cwr_poll_interval" in
  ''|*[!0-9]*) _cwr_poll_interval=15 ;;
esac

# Compute deadline: try to resume from ledger, otherwise start now
_cwr_deadline_start=""
_cwr_deadline_start="$(_cwr_read_deadline_start 2>/dev/null)" || _cwr_deadline_start=""

_cwr_now="$(date +%s)"
if [ -n "$_cwr_deadline_start" ] && [ "$_cwr_deadline_start" -gt 0 ] 2>/dev/null; then
  _cwr_elapsed=$((_cwr_now - _cwr_deadline_start))
  if [ "$_cwr_elapsed" -ge "$_cwr_max_seconds" ]; then
    _cwr_log "deadline already expired (started ${_cwr_elapsed}s ago, max ${_cwr_max_seconds}s)"
    printf 'pending\n'
    exit 2
  fi
  _cwr_remaining=$((_cwr_max_seconds - _cwr_elapsed))
  _cwr_log "resuming CI wait: ${_cwr_elapsed}s elapsed, ${_cwr_remaining}s remaining"
else
  _cwr_remaining="$_cwr_max_seconds"
fi

_cwr_deadline=$((_cwr_now + _cwr_remaining))

# Skip gh if requested (testing)
if [ "${CI_WAIT_REF_SKIP_GH:-}" = "1" ]; then
  _cwr_log "none-observed (gh skipped)"
  printf 'none-observed\n'
  exit 3
fi

if ! command -v gh >/dev/null 2>&1; then
  _cwr_log "none-observed (gh not available)"
  printf 'none-observed\n'
  exit 3
fi

# Read configured workflows and status contexts
_cwr_workflows=""
_cwr_workflows="$(_cwr_read_configured_workflows 2>/dev/null)" || _cwr_workflows=""

_cwr_status_contexts=""
_cwr_status_contexts="$(_cwr_read_status_contexts 2>/dev/null)" || _cwr_status_contexts=""

# _cwr_is_declared_context <context> — check if a status context is declared.
_cwr_is_declared_context() {
  local ctx="$1"
  if [ -z "$_cwr_status_contexts" ]; then
    return 1  # default empty = nothing declared
  fi
  printf '%s\n' "$_cwr_status_contexts" | /usr/bin/grep -qFx "$ctx"
}

# _cwr_is_configured_workflow <name> — check if a check-run name matches
# a configured workflow.
_cwr_is_configured_workflow() {
  local name="$1"
  if [ -z "$_cwr_workflows" ]; then
    # No workflows configured — accept all check runs
    return 0
  fi
  local wf=""
  while IFS= read -r wf; do
    [ -z "$wf" ] && continue
    # Match if the check run name starts with or equals the workflow name
    case "$name" in
      "${wf}"*) return 0 ;;
    esac
  done <<< "$_cwr_workflows"
  return 1
}

# --- Main poll loop ---
while true; do
  _cwr_now="$(date +%s)"
  if [ "$_cwr_now" -ge "$_cwr_deadline" ]; then
    _cwr_log "timeout: ${_cwr_max_seconds}s exceeded"
    printf 'pending\n'
    exit 2
  fi

  # Compute remaining seconds for bounded gh calls
  _cwr_call_remaining=$((_cwr_deadline - $(date +%s)))
  [ "$_cwr_call_remaining" -lt 1 ] && _cwr_call_remaining=1

  # Query check runs on the commit (bounded)
  _cwr_checks=""
  _cwr_checks="$(bound_exec "$_cwr_call_remaining" -- gh api "repos/{owner}/{repo}/commits/${_cwr_sha}/check-runs" --jq '.check_runs[] | "\(.name)|\(.status)|\(.conclusion)"' 2>/dev/null)" || _cwr_checks=""

  # Query commit statuses (for declared contexts, bounded)
  _cwr_statuses=""
  if [ -n "$_cwr_status_contexts" ]; then
    _cwr_call_remaining=$((_cwr_deadline - $(date +%s)))
    [ "$_cwr_call_remaining" -lt 1 ] && _cwr_call_remaining=1
    _cwr_statuses="$(bound_exec "$_cwr_call_remaining" -- gh api "repos/{owner}/{repo}/commits/${_cwr_sha}/statuses" --jq '.[] | "\(.context)|\(.state)"' 2>/dev/null)" || _cwr_statuses=""
  fi

  # Analyze check runs
  _cwr_any_found=0
  _cwr_any_pending=0
  _cwr_any_failed=0
  _cwr_all_green=1

  if [ -n "$_cwr_checks" ]; then
    while IFS= read -r _cwr_line; do
      [ -z "$_cwr_line" ] && continue
      _cwr_check_name="$(printf '%s' "$_cwr_line" | cut -d'|' -f1)"
      _cwr_check_status="$(printf '%s' "$_cwr_line" | cut -d'|' -f2)"
      _cwr_check_conclusion="$(printf '%s' "$_cwr_line" | cut -d'|' -f3)"

      # Filter by configured workflows
      if ! _cwr_is_configured_workflow "$_cwr_check_name"; then
        continue
      fi

      _cwr_any_found=1

      if [ "$_cwr_check_status" != "completed" ]; then
        _cwr_any_pending=1
        _cwr_all_green=0
      elif [ "$_cwr_check_conclusion" != "success" ] && [ "$_cwr_check_conclusion" != "skipped" ]; then
        _cwr_any_failed=1
        _cwr_all_green=0
      fi
    done <<< "$_cwr_checks"
  fi

  # Analyze commit statuses (only declared contexts)
  if [ -n "$_cwr_statuses" ]; then
    while IFS= read -r _cwr_sline; do
      [ -z "$_cwr_sline" ] && continue
      _cwr_status_ctx="$(printf '%s' "$_cwr_sline" | cut -d'|' -f1)"
      _cwr_status_state="$(printf '%s' "$_cwr_sline" | cut -d'|' -f2)"

      if ! _cwr_is_declared_context "$_cwr_status_ctx"; then
        continue  # Undeclared context — ignored
      fi

      _cwr_any_found=1

      case "$_cwr_status_state" in
        success) ;;
        pending) _cwr_any_pending=1; _cwr_all_green=0 ;;
        failure|error) _cwr_any_failed=1; _cwr_all_green=0 ;;
      esac
    done <<< "$_cwr_statuses"
  fi

  # Decide result
  if [ "$_cwr_any_found" -eq 0 ]; then
    # First iteration: no checks yet, wait
    _cwr_log "no check runs observed yet, waiting..."
  elif [ "$_cwr_any_failed" -eq 1 ]; then
    _cwr_log "red: at least one check failed"
    printf 'red\n'
    exit 1
  elif [ "$_cwr_all_green" -eq 1 ]; then
    _cwr_log "green: all configured checks passed"
    printf 'green\n'
    exit 0
  fi
  # else: pending, loop

  # Sleep before next poll
  sleep "$_cwr_poll_interval" 2>/dev/null || sleep 1
done
