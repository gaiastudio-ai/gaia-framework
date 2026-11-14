#!/usr/bin/env bash
# bats-shard-retry.sh — retry failed bats test files once within a shard step.
#
# Usage:
#   bats-shard-retry.sh [--summary-file <path>] [--junit-dir <path>] \
#     -- <bats-args...>
#
# Runs bats with the given arguments. If any test files fail, re-runs ONLY the
# failed files once. A file that fails again still fails the shard. Every retry
# is logged by test name to the summary file (default: $GITHUB_STEP_SUMMARY).
#
# Failed files are identified from the JUnit XML in --junit-dir (or the -o dir
# from the bats args). When no JUnit output is available, all files are retried.
#
# Retry is suppressed when the first run was killed by a signal (timeout or
# cancellation) — exit codes >= 128 are never retried.
#
# Exit codes:
#   0 — all tests passed (first attempt or retry)
#   N — bats exit code from the final failed run

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# parse our flags vs bats arguments
# ---------------------------------------------------------------------------
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"
JUNIT_DIR=""
BATS_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --summary-file) SUMMARY_FILE="$2"; shift 2 ;;
    --junit-dir) JUNIT_DIR="$2"; shift 2 ;;
    --)
      shift
      BATS_ARGS=("$@")
      break
      ;;
    *) BATS_ARGS=("$@"); break ;;
  esac
done

if [ ${#BATS_ARGS[@]} -eq 0 ]; then
  printf 'bats-shard-retry.sh: no bats arguments provided\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
_log_summary() {
  if [ -n "$SUMMARY_FILE" ]; then
    printf '%s\n' "$*" >> "$SUMMARY_FILE"
  fi
}

_extract_test_files() {
  for f in "$@"; do
    case "$f" in *.bats) printf '%s\n' "$f" ;; esac
  done
}

# Find the -o (output dir) from bats args if --junit-dir was not given
_find_junit_dir() {
  if [ -n "$JUNIT_DIR" ]; then
    printf '%s' "$JUNIT_DIR"
    return
  fi
  local prev=""
  for arg in "${BATS_ARGS[@]}"; do
    if [ "$prev" = "-o" ]; then
      printf '%s' "$arg"
      return
    fi
    prev="$arg"
  done
}

# Extract non-file bats options (everything that isn't a .bats file)
_extract_bats_options() {
  for arg in "$@"; do
    case "$arg" in *.bats) ;; *) printf '%s\n' "$arg" ;; esac
  done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# Collect test files
TEST_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && TEST_FILES+=("$f")
done < <(_extract_test_files "${BATS_ARGS[@]}")

if [ ${#TEST_FILES[@]} -eq 0 ]; then
  printf 'bats-shard-retry.sh: no .bats files found in arguments\n' >&2
  exit 1
fi

# First run — pass ALL original arguments to bats unchanged
set +e
bats "${BATS_ARGS[@]}"
first_exit=$?
set -e

# Pass on first attempt
if [ "$first_exit" -eq 0 ]; then
  exit 0
fi

# Never retry on signal kills (timeout, cancellation, OOM)
if [ "$first_exit" -ge 128 ]; then
  printf 'bats-shard-retry.sh: bats exited %d (signal %d) — not retrying\n' \
    "$first_exit" "$((first_exit - 128))" >&2
  exit "$first_exit"
fi

# Identify failed test files from JUnit XML
JUNIT="$(_find_junit_dir)"
FAILED_FILES=()
if [ -n "$JUNIT" ] && [ -f "$JUNIT/report.xml" ]; then
  while IFS= read -r failed_name; do
    [ -z "$failed_name" ] && continue
    for tf in "${TEST_FILES[@]}"; do
      if [ "$(basename "$tf")" = "$failed_name" ]; then
        FAILED_FILES+=("$tf")
        break
      fi
    done
  done < <(python3 -I -c "
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1])
for ts in tree.iter('testsuite'):
    name = ts.get('name', '')
    if not name.endswith('.bats'): continue
    failures = int(ts.get('failures', 0))
    errors = int(ts.get('errors', 0))
    if failures > 0 or errors > 0:
        print(name)
" "$JUNIT/report.xml" 2>/dev/null || true)
fi

# If we could not identify specific failures, do NOT retry the entire suite.
# A blind retry-all doubles the CI wall-clock for no benefit. Log a warning
# and exit with the first-pass status so the failure is visible immediately.
if [ ${#FAILED_FILES[@]} -eq 0 ]; then
  printf 'bats-shard-retry.sh: no JUnit report found — cannot identify failed files; skipping retry\n' >&2
  _log_summary ""
  _log_summary "### Shard retry skipped"
  _log_summary ""
  _log_summary "No JUnit XML report available — cannot identify which files failed."
  _log_summary "Exiting with the first-pass status ($first_exit)."
  exit "$first_exit"
fi

# Log the retry
_log_summary ""
_log_summary "### Shard retry"
_log_summary ""
_log_summary "Retrying ${#FAILED_FILES[@]} failed file(s):"
for f in "${FAILED_FILES[@]}"; do
  printf 'bats-shard-retry.sh: retrying %s\n' "$f" >&2
  _log_summary "- \`$(basename "$f")\`"
done

# Build retry command: same bats options but only the failed files
BATS_OPTS=()
while IFS= read -r opt; do
  [ -n "$opt" ] && BATS_OPTS+=("$opt")
done < <(_extract_bats_options "${BATS_ARGS[@]}")

set +e
bats "${BATS_OPTS[@]}" "${FAILED_FILES[@]}"
retry_exit=$?
set -e

if [ "$retry_exit" -eq 0 ]; then
  _log_summary ""
  _log_summary "All retried files passed on second attempt."
else
  _log_summary ""
  _log_summary "Retry failed — shard reports failure."
fi

exit "$retry_exit"
