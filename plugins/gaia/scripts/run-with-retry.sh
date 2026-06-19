#!/usr/bin/env bash
# run-with-retry.sh — flaky-test auto-retry with escalation policy
#
# Purpose:
#   Wraps a test command invocation with retry logic for flaky tests.
#   When a test is marked as flaky (via --is-flaky flag or --flaky-list-file
#   lookup), failures are retried up to --retry-limit additional attempts.
#   If all attempts fail, the failure is ESCALATED (promoted to a real failure
#   that blocks the pipeline). Non-flaky test failures pass through immediately
#   with no retry.
#
# Usage:
#   run-with-retry.sh \
#     --test-id <id> \
#     [--retry-limit <n>] \
#     [--is-flaky] \
#     [--flaky-list-file <path>] \
#     [--help] \
#     -- <cmd> [args...]
#
# Flags:
#   --test-id ID           Required. Identifier for the test being run.
#   --retry-limit N        Max additional retries for flaky tests (default: 2).
#   --is-flaky             Explicit flag marking this test as flaky.
#   --flaky-list-file PATH File with one flaky test id per line; if --test-id
#                          is found in this file, the test is treated as flaky.
#   --help                 Print usage and exit 0.
#   -- <cmd> [args...]     The test command to execute (everything after --).
#
# Output:
#   stderr — retry progress and ESCALATED_FLAKY_FAILURE on budget exhaustion.
#
# Exit codes:
#   0 — test passed (on first attempt or a retry)
#   N — last nonzero exit code from the test command (failure/escalation)
#
# Design notes:
#   - Non-flaky failures: immediate passthrough, zero retries, no ESCALATED.
#   - retry_limit=0: zero additional retries → 1 total attempt for flaky tests.
#   - Escalation is intentionally aggressive: exhausted retries become real
#     failures to prevent silent regressions.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------
_log_info() { printf '[run-with-retry] INFO: %s\n' "$*" >&2; }
_log_warn() { printf '[run-with-retry] WARN: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# is_flaky_test — check if a test id is in the flaky list file
#
# Args: $1=test_id  $2=flaky_list_file
# Output: "1" if flaky, "0" otherwise.
# ---------------------------------------------------------------------------
is_flaky_test() {
  local test_id="$1"
  local flaky_list_file="${2:-}"

  if [ -z "$flaky_list_file" ] || [ ! -f "$flaky_list_file" ]; then
    printf '0'
    return 0
  fi

  if grep -qxF "$test_id" "$flaky_list_file" 2>/dev/null; then
    printf '1'
  else
    printf '0'
  fi
}

# ---------------------------------------------------------------------------
# run_with_retry — execute a command with optional retry for flaky tests
#
# Args: $1=test_id  $2=retry_limit  $3=is_flaky_flag  $4..=cmd [args...]
#
# Logic:
#   1. Run the command once (attempt 1).
#   2. If it passes → exit 0.
#   3. If it fails and NOT flaky → exit with the failure code immediately.
#   4. If it fails and IS flaky → retry up to retry_limit additional times.
#      - If any retry passes → exit 0.
#      - If all attempts fail → print ESCALATED_FLAKY_FAILURE to stderr,
#        exit with the last nonzero exit code.
# ---------------------------------------------------------------------------
run_with_retry() {
  local test_id="$1"
  local retry_limit="$2"
  local is_flaky_flag="$3"
  shift 3

  local last_exit=0

  # Attempt 1
  set +e
  "$@"
  last_exit=$?
  set -e

  # Pass on first attempt
  if [ "$last_exit" -eq 0 ]; then
    return 0
  fi

  # Non-flaky failure: immediate passthrough
  if [ "$is_flaky_flag" -ne 1 ]; then
    return "$last_exit"
  fi

  # Flaky: retry up to retry_limit additional times
  local attempt=0
  while [ "$attempt" -lt "$retry_limit" ]; do
    attempt=$((attempt + 1))
    _log_info "retry $attempt/$retry_limit for test_id=$test_id"

    set +e
    "$@"
    last_exit=$?
    set -e

    if [ "$last_exit" -eq 0 ]; then
      _log_info "test_id=$test_id passed on retry $attempt"
      return 0
    fi
  done

  # All attempts exhausted — escalate
  local total=$((1 + retry_limit))
  printf 'ESCALATED_FLAKY_FAILURE: test_id=%s retries_exhausted=%d\n' \
    "$test_id" "$total" >&2
  return "$last_exit"
}

# ---------------------------------------------------------------------------
# parse_args — populate TEST_ID, RETRY_LIMIT, IS_FLAKY, FLAKY_LIST_FILE,
#              CMD_ARGS
# ---------------------------------------------------------------------------
parse_args() {
  TEST_ID=""
  RETRY_LIMIT=2
  IS_FLAKY=0
  FLAKY_LIST_FILE=""
  CMD_ARGS=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --test-id)
        TEST_ID="$2"; shift 2 ;;
      --retry-limit)
        RETRY_LIMIT="$2"; shift 2 ;;
      --is-flaky)
        IS_FLAKY=1; shift ;;
      --flaky-list-file)
        FLAKY_LIST_FILE="$2"; shift 2 ;;
      --help|-h)
        printf 'Usage: run-with-retry.sh --test-id <id> [--retry-limit <n>] [--is-flaky] [--flaky-list-file <path>] -- <cmd> [args...]\n'
        exit 0 ;;
      --)
        shift
        CMD_ARGS=("$@")
        break ;;
      *)
        printf 'run-with-retry.sh: unknown option: %s\n' "$1" >&2
        exit 1 ;;
    esac
  done

  if [ -z "$TEST_ID" ]; then
    printf 'run-with-retry.sh: --test-id is required\n' >&2
    exit 1
  fi

  if [ ${#CMD_ARGS[@]} -eq 0 ]; then
    printf 'run-with-retry.sh: no command specified after --\n' >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  # If not explicitly flaky, check the flaky-list-file
  if [ "$IS_FLAKY" -eq 0 ] && [ -n "$FLAKY_LIST_FILE" ]; then
    local check
    check="$(is_flaky_test "$TEST_ID" "$FLAKY_LIST_FILE")"
    if [ "$check" = "1" ]; then
      IS_FLAKY=1
    fi
  fi

  run_with_retry "$TEST_ID" "$RETRY_LIMIT" "$IS_FLAKY" "${CMD_ARGS[@]}"
}

# Main-guard: only invoke main when executed directly (not when sourced).
# Required for NFR-052 — sourcing must expose public functions without side-effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
