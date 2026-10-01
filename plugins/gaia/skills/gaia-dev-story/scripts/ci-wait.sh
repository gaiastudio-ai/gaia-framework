#!/usr/bin/env bash
# ci-wait.sh — gaia-dev-story CI status polling
#
# Polls CI check status for a PR using jq-based JSON parsing with --required
# check filtering, configurable timeout, two-poll stability rule, and a grace
# window for late-registering checks.
#
# Usage:
#   ci-wait.sh <pr_number> [--timeout <minutes>]
#
# Environment:
#   PROJECT_PATH — required. The git working directory. Resolved and entered
#                  BEFORE the non-git guard runs and before arguments are
#                  parsed, so relative path arguments resolve against it.
#   CI_WAIT_POLL_INTERVAL — override poll cadence (seconds, default 30).
#                           Must be a non-negative integer; invalid values
#                           are ignored with a warning (falls back to 30).
#   CI_WAIT_NO_CHECKS_GRACE_SECONDS — override grace window (default 300).
#                                      Must be a non-negative integer; invalid
#                                      values fall back to 300 with a warning.
#   GAIA_SHARED_CONFIG — explicit path to project config (forwarded to
#                         resolve-config.sh; if unset the resolver discovers
#                         config via PROJECT_ROOT / CLAUDE_PROJECT_ROOT /
#                         walk-up).
#
# Exit codes:
#   0 — all CI checks passed (or non-git skip, or no CI configured)
#   1 — CI check failed, cancelled, or timeout exceeded

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/ci-wait.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# Non-git CWD guard: skip-with-warning when CWD is outside any git work tree.
# CI polling is meaningless when there is no PR (there's no repo).
# shellcheck source=../../../scripts/lib/non-git-cwd-guard.sh
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$GUARD_DIR/../../../scripts/lib/non-git-cwd-guard.sh"
# Resolve the working directory BEFORE the non-git guard: the guard reads
# CWD, so it must test the directory this script is meant to act on, not the
# caller's. Argument parsing follows, so relative path arguments resolve
# against PROJECT_PATH.
WORK_DIR="${PROJECT_PATH:-.}"
cd "$WORK_DIR" || die "cannot cd to $WORK_DIR"

non_git_cwd_skip "$SCRIPT_NAME" || exit 0

# --- Argument parsing ---
if [ $# -lt 1 ]; then
  die "usage: ci-wait.sh <pr_number> [--timeout <minutes>]"
fi

PR_NUMBER="$1"
shift

CLI_TIMEOUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      [ $# -ge 2 ] || die "--timeout requires a value"
      CLI_TIMEOUT="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

# --- --timeout validation ---
if [ -n "$CLI_TIMEOUT" ]; then
  # Must be a single-line decimal integer with no leading zeros (08 is
  # ambiguous octal). case operates on the whole string, unlike grep which
  # matches per-line and would accept embedded newlines.
  case "$CLI_TIMEOUT" in
    0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) ;;
    *) die "--timeout must be an integer, got: '$CLI_TIMEOUT'" ;;
  esac
  if [ "$CLI_TIMEOUT" -gt 1440 ]; then
    die "--timeout must be at most 1440 (24 hours), got: '$CLI_TIMEOUT'"
  fi
fi

# --- Tool checks ---
if ! command -v gh >/dev/null 2>&1; then
  die "Required tool gh not found. Install it to poll CI status."
fi
if ! command -v jq >/dev/null 2>&1; then
  die "Required tool jq not found. Install it to parse CI check output."
fi

# --- Timeout resolution ---
# Precedence: CLI --timeout > config ci_cd.ci_wait_timeout_minutes > default 30
TIMEOUT_MINUTES=""
if [ -n "$CLI_TIMEOUT" ]; then
  TIMEOUT_MINUTES="$CLI_TIMEOUT"
else
  # Try config resolution via resolve-config.sh subprocess.
  # The resolver discovers config via --shared, PROJECT_ROOT,
  # CLAUDE_PROJECT_ROOT, or walk-up — always call it.
  RESOLVE_SCRIPT="$GUARD_DIR/../../../scripts/resolve-config.sh"
  if [ -x "$RESOLVE_SCRIPT" ]; then
    config_val=""
    if [ -n "${GAIA_SHARED_CONFIG:-}" ]; then
      config_val=$("$RESOLVE_SCRIPT" --shared "$GAIA_SHARED_CONFIG" --field ci_cd.ci_wait_timeout_minutes 2>/dev/null) || true
    else
      config_val=$("$RESOLVE_SCRIPT" --field ci_cd.ci_wait_timeout_minutes 2>/dev/null) || true
    fi
    if [ -n "$config_val" ]; then
      # Validate: must be a decimal integer (no leading zeros) in 1-360.
      # Distinguish "not a whole number" from "out of range".
      case "$config_val" in
        0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9])
          if [ "$config_val" -ge 1 ] 2>/dev/null && [ "$config_val" -le 360 ] 2>/dev/null; then
            TIMEOUT_MINUTES="$config_val"
          else
            log "config ci_wait_timeout_minutes value '$config_val' out of range (1-360), using default"
          fi ;;
        *)
          log "config ci_wait_timeout_minutes value '$config_val' is not a whole number, using default"
          ;;
      esac
    fi
  fi
fi
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-30}"
TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60))

# --- Poll interval validation ---
POLL_INTERVAL="${CI_WAIT_POLL_INTERVAL:-30}"
if ! printf '%s' "$POLL_INTERVAL" | grep -qE '^[0-9]+$'; then
  log "CI_WAIT_POLL_INTERVAL='$POLL_INTERVAL' is not a non-negative integer, using default 30"
  POLL_INTERVAL=30
fi

# --- Grace seconds validation ---
GRACE_SECONDS="${CI_WAIT_NO_CHECKS_GRACE_SECONDS:-300}"
if ! printf '%s' "$GRACE_SECONDS" | grep -qE '^[0-9]+$'; then
  log "CI_WAIT_NO_CHECKS_GRACE_SECONDS='$GRACE_SECONDS' is not a non-negative integer, using default 300"
  GRACE_SECONDS=300
fi

CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5

# Track wall clock with $SECONDS (bash built-in, safe on 3.2+)
SECONDS=0

# Two-poll stability state
PREV_TERMINAL_NAMES=""
STABILITY_COUNT=0

# Whether the --required flag is unsupported (fall back without retrying it)
REQUIRED_PERMANENT_FAIL=0
REQUIRED_PERMANENT_WARNED=0

# Grace window state
GRACE_STARTED=0
GRACE_START_TIME=0

# Centralized temp-file cleanup — every mktemp result is appended here
_TMPFILES=""
_cleanup() { for f in $_TMPFILES; do rm -f "$f"; done; }
trap _cleanup EXIT

log "waiting for CI checks on PR #${PR_NUMBER} (timeout: ${TIMEOUT_MINUTES}m)"

# --- Helpers ---

# _validate_json RAW — check raw output is a JSON array of objects.
# Returns 0 if valid, 1 if not.
_validate_json() {
  printf '%s' "$1" | jq -e 'type == "array" and all(type == "object")' >/dev/null 2>&1
}

# _extract_names_sorted JSON — extract sorted check names from JSON array.
_extract_names_sorted() {
  printf '%s' "$1" | jq -r '.[].name' 2>/dev/null | sort
}

# _count_bucket JSON BUCKET — count checks with the given bucket value.
_count_bucket() {
  printf '%s' "$1" | jq --arg b "$2" '[.[] | select(.bucket == $b)] | length' 2>/dev/null || printf '0'
}

# _failed_check_names JSON — extract names of failed/cancelled checks.
_failed_check_names() {
  printf '%s' "$1" | jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | "\(.name) (\(.bucket))"' 2>/dev/null
}

# _find_config_file — locate the project config file using the resolver's
# lookup order: GAIA_SHARED_CONFIG, PROJECT_ROOT, CLAUDE_PROJECT_ROOT, PWD,
# then walk-up from PWD (stops at $HOME, skipped when GAIA_NO_PROJECT_WALKUP
# or CLAUDE_SKILL_DIR is set).
_find_config_file() {
  # Explicit path via environment
  if [ -n "${GAIA_SHARED_CONFIG:-}" ]; then
    printf '%s' "$GAIA_SHARED_CONFIG"
    return 0
  fi
  # Walk the resolver's discovery chain
  local candidate="" root=""
  for root in "${PROJECT_ROOT:-}" "${CLAUDE_PROJECT_ROOT:-}" "$PWD"; do
    [ -z "$root" ] && continue
    for candidate in \
      "$root/.gaia/config/project-config.yaml" \
      "$root/config/project-config.yaml"; do
      if [ -f "$candidate" ]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  done
  # Walk-up from PWD (mirrors resolve-config.sh ~L586-599)
  if [ -z "${CLAUDE_SKILL_DIR:-}" ] && [ -z "${GAIA_NO_PROJECT_WALKUP:-}" ]; then
    local walk_dir="$PWD"
    while [ "$walk_dir" != "/" ] && [ "$walk_dir" != "${HOME:-/nonexistent}" ]; do
      walk_dir="$(dirname "$walk_dir")"
      if [ -f "${walk_dir}/.gaia/config/project-config.yaml" ]; then
        printf '%s' "${walk_dir}/.gaia/config/project-config.yaml"
        return 0
      elif [ -f "${walk_dir}/config/project-config.yaml" ]; then
        printf '%s' "${walk_dir}/config/project-config.yaml"
        return 0
      fi
    done
  fi
  return 1
}

# _grace_decision PR_NUMBER — when no checks appear after grace, decide exit.
# Uses base branch + promotion_chain ci_checks to decide:
#   - No CI configured → exit 0
#   - CI expected → exit 1 naming the checks
_grace_decision() {
  local pr_num="$1"
  local base_branch="" pr_view_out=""

  # Get base branch
  pr_view_out=$(gh pr view "$pr_num" --json baseRefName 2>/dev/null) || {
    die "grace expired: could not determine base branch for PR #${pr_num}"
  }
  base_branch=$(printf '%s' "$pr_view_out" | jq -r '.baseRefName // empty' 2>/dev/null)
  if [ -z "$base_branch" ]; then
    die "grace expired: could not determine base branch for PR #${pr_num}"
  fi

  # Locate config file via resolver's discovery order
  local config_file=""
  config_file=$(_find_config_file) || {
    die "grace expired: no config available to determine expected CI checks"
  }
  if [ -d "$config_file" ]; then
    die "grace expired: config path is a directory, not a file"
  fi
  if [ ! -r "$config_file" ]; then
    die "grace expired: config file not readable"
  fi

  if ! command -v yq >/dev/null 2>&1; then
    die "grace expired: yq not found, cannot read CI check configuration"
  fi

  # Read ci_checks from config — capture yq exit code and stderr separately.
  local ci_checks="" yq_stderr="" yq_ec=0
  local yq_stderr_file
  yq_stderr_file=$(mktemp "${TMPDIR:-/tmp}/ci-wait-yq-stderr.XXXXXX")
  _TMPFILES="$_TMPFILES $yq_stderr_file"
  ci_checks=$(branch="$base_branch" yq -r \
    '.ci_cd.promotion_chain[] | select(.branch == strenv(branch)) | .ci_checks // [] | .[]' \
    "$config_file" 2>"$yq_stderr_file") || yq_ec=$?
  yq_stderr=$(cat "$yq_stderr_file")
  rm -f "$yq_stderr_file"

  if [ "$yq_ec" -ne 0 ]; then
    die "grace expired: failed to read config ($config_file): $yq_stderr"
  fi

  if [ -z "$ci_checks" ]; then
    log "grace expired: no CI checks configured for branch '$base_branch' — exiting OK"
    echo "passed"
    exit 0
  else
    die "grace expired: expected checks never appeared: $ci_checks"
  fi
}

# --- Main poll loop ---
while true; do
  # Check timeout (wall clock)
  if [ "$SECONDS" -ge "$TIMEOUT_SECONDS" ]; then
    log "CI checks timed out after ${TIMEOUT_MINUTES} minutes."
    log "Resume with /gaia-resume after checks complete."
    exit 1
  fi

  # --- Poll required checks ---
  local_stdout=""
  local_stderr=""
  local_ec=0

  if [ "$REQUIRED_PERMANENT_FAIL" -eq 1 ]; then
    # Skip the --required call entirely when the flag is unsupported
    use_all_checks=1
    checks_json=""
    if [ "$REQUIRED_PERMANENT_WARNED" -eq 0 ]; then
      log "WARNING: gh does not support --required flag, falling back to all checks"
      REQUIRED_PERMANENT_WARNED=1
    fi
  else
    local_stderr_file=$(mktemp "${TMPDIR:-/tmp}/ci-wait-stderr.XXXXXX")
    _TMPFILES="$_TMPFILES $local_stderr_file"
    local_stdout=$(gh pr checks "$PR_NUMBER" --required --json name,state,bucket 2>"$local_stderr_file") || local_ec=$?
    local_stderr=$(cat "$local_stderr_file")
    rm -f "$local_stderr_file"

    use_all_checks=0
    checks_json=""

    if [ "$local_ec" -ne 0 ]; then
      # Distinguish "no required checks" from other errors
      if printf '%s' "$local_stderr" | grep -qi 'no required checks'; then
        log "no required checks configured, using all checks"
        use_all_checks=1
      elif printf '%s' "$local_stderr" | grep -qi 'no checks reported'; then
        log "no checks reported, using all checks"
        use_all_checks=1
      elif printf '%s' "$local_stderr" | grep -qi 'unknown flag'; then
        log "WARNING: gh does not support --required flag, falling back to all checks"
        REQUIRED_PERMANENT_FAIL=1
        REQUIRED_PERMANENT_WARNED=1
        use_all_checks=1
      else
        # Transient error
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
          die "CI polling failed ${MAX_CONSECUTIVE_FAILURES} consecutive times. Last error: $local_stderr"
        fi
        log "polling error (attempt ${CONSECUTIVE_FAILURES}/${MAX_CONSECUTIVE_FAILURES})"
        # Reset two-poll stability on retry-path errors
        PREV_TERMINAL_NAMES=""
        STABILITY_COUNT=0
        sleep "$POLL_INTERVAL"
        continue
      fi
    else
      # Validate the JSON
      if ! _validate_json "$local_stdout"; then
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
          die "CI polling failed ${MAX_CONSECUTIVE_FAILURES} consecutive times. Invalid JSON output."
        fi
        log "polling error: invalid JSON (attempt ${CONSECUTIVE_FAILURES}/${MAX_CONSECUTIVE_FAILURES})"
        # Reset two-poll stability on retry-path errors
        PREV_TERMINAL_NAMES=""
        STABILITY_COUNT=0
        sleep "$POLL_INTERVAL"
        continue
      fi

      # Empty required array → treat as "no required checks" (enter all-checks path)
      required_count=$(printf '%s' "$local_stdout" | jq 'length' 2>/dev/null || printf '0')
      if [ "$required_count" -eq 0 ]; then
        log "no required checks configured, using all checks"
        use_all_checks=1
      else
        checks_json="$local_stdout"
      fi
    fi
  fi

  # --- Fall back to all-checks if needed ---
  if [ "$use_all_checks" -eq 1 ]; then
    all_stdout=""
    all_stderr_file=$(mktemp "${TMPDIR:-/tmp}/ci-wait-stderr.XXXXXX")
    _TMPFILES="$_TMPFILES $all_stderr_file"
    all_ec=0
    all_stdout=$(gh pr checks "$PR_NUMBER" --json name,state,bucket 2>"$all_stderr_file") || all_ec=$?
    all_stderr=$(cat "$all_stderr_file")
    rm -f "$all_stderr_file"

    if [ "$all_ec" -ne 0 ]; then
      if printf '%s' "$all_stderr" | grep -qi 'no checks reported'; then
        # No checks at all — enter grace window
        if [ "$GRACE_STARTED" -eq 0 ]; then
          GRACE_STARTED=1
          GRACE_START_TIME="$SECONDS"
          log "no checks reported yet, entering grace window (${GRACE_SECONDS}s)"
        fi
        grace_elapsed=$((SECONDS - GRACE_START_TIME))
        if [ "$grace_elapsed" -ge "$GRACE_SECONDS" ]; then
          _grace_decision "$PR_NUMBER"
        fi
        # Reset two-poll stability during grace polls
        PREV_TERMINAL_NAMES=""
        STABILITY_COUNT=0
        sleep "$POLL_INTERVAL"
        continue
      fi
      CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
        die "CI polling failed ${MAX_CONSECUTIVE_FAILURES} consecutive times. Last error: $all_stderr"
      fi
      log "polling error (attempt ${CONSECUTIVE_FAILURES}/${MAX_CONSECUTIVE_FAILURES})"
      # Reset two-poll stability on retry-path errors
      PREV_TERMINAL_NAMES=""
      STABILITY_COUNT=0
      sleep "$POLL_INTERVAL"
      continue
    fi

    if ! _validate_json "$all_stdout"; then
      CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
        die "CI polling failed ${MAX_CONSECUTIVE_FAILURES} consecutive times. Invalid JSON output."
      fi
      log "polling error: invalid JSON (attempt ${CONSECUTIVE_FAILURES}/${MAX_CONSECUTIVE_FAILURES})"
      # Reset two-poll stability on retry-path errors
      PREV_TERMINAL_NAMES=""
      STABILITY_COUNT=0
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Empty array from all-checks also means grace window
    all_count=$(printf '%s' "$all_stdout" | jq 'length' 2>/dev/null || printf '0')
    if [ "$all_count" -eq 0 ]; then
      if [ "$GRACE_STARTED" -eq 0 ]; then
        GRACE_STARTED=1
        GRACE_START_TIME="$SECONDS"
        log "no checks reported yet, entering grace window (${GRACE_SECONDS}s)"
      fi
      grace_elapsed=$((SECONDS - GRACE_START_TIME))
      if [ "$grace_elapsed" -ge "$GRACE_SECONDS" ]; then
        _grace_decision "$PR_NUMBER"
      fi
      # Reset two-poll stability during grace polls
      PREV_TERMINAL_NAMES=""
      STABILITY_COUNT=0
      sleep "$POLL_INTERVAL"
      continue
    fi

    checks_json="$all_stdout"
  fi

  # Reset consecutive failures only after a successful parse
  CONSECUTIVE_FAILURES=0

  # Also handle empty --required response
  if [ -z "$checks_json" ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Reset grace window once checks appear
  GRACE_STARTED=0

  # --- Evaluate check results ---
  failed_count=$(_count_bucket "$checks_json" "fail")
  cancelled_count=$(_count_bucket "$checks_json" "cancel")
  pending_count=$(_count_bucket "$checks_json" "pending")

  # Failed or cancelled checks → immediate failure
  if [ "$failed_count" -gt 0 ] || [ "$cancelled_count" -gt 0 ]; then
    fail_names=$(_failed_check_names "$checks_json")
    log "CI check(s) failed or cancelled:"
    printf '%s\n' "$fail_names" | while IFS= read -r line; do
      log "  $line"
    done
    die "Fix the issue, push again, and resume with /gaia-resume."
  fi

  # Pending checks → keep polling
  if [ "$pending_count" -gt 0 ]; then
    log "CI checks in progress (${pending_count} pending, elapsed: ${SECONDS}s)..."
    # Reset two-poll stability on non-terminal poll
    PREV_TERMINAL_NAMES=""
    STABILITY_COUNT=0
    sleep "$POLL_INTERVAL"
    continue
  fi

  # --- All checks terminal — apply two-poll stability rule ---
  current_names=$(_extract_names_sorted "$checks_json")

  if [ "$current_names" = "$PREV_TERMINAL_NAMES" ]; then
    STABILITY_COUNT=$((STABILITY_COUNT + 1))
  else
    # New or changed check set — reset
    STABILITY_COUNT=1
    PREV_TERMINAL_NAMES="$current_names"
  fi

  if [ "$STABILITY_COUNT" -ge 2 ]; then
    log "all CI checks passed (elapsed: ${SECONDS}s)"
    echo "passed"
    exit 0
  fi

  log "all checks terminal, confirming stability (poll ${STABILITY_COUNT}/2, elapsed: ${SECONDS}s)..."
  sleep "$POLL_INTERVAL"
done
