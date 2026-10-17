#!/usr/bin/env bash
# validate-shard-assignments.sh — CI guard that fails when any top-level
# .bats file under plugins/gaia/tests/ is missing from the shard assignment
# file.  Forces developers to classify every new test file into a shard.
#
# Exit codes:
#   0 — every .bats file is assigned to exactly one shard
#   1 — one or more files are unassigned (names printed to stderr)

set -euo pipefail

REPO_ROOT="${1:-.}"
ASSIGNMENT_FILE="$REPO_ROOT/.github/bats-shard-assignments.tsv"
TESTS_DIR="$REPO_ROOT/plugins/gaia/tests"

if [ ! -f "$ASSIGNMENT_FILE" ]; then
  echo "ERROR: shard assignment file not found: $ASSIGNMENT_FILE" >&2
  exit 1
fi

# Collect assigned files (skip comment lines, extract column 2).
assigned=$(grep -v '^#' "$ASSIGNMENT_FILE" | awk -F'\t' '{print $2}' | sort -u)

# Collect actual top-level .bats files.
actual=$(find "$TESTS_DIR" -maxdepth 1 -name '*.bats' -exec basename {} \; | sort -u)

# Find files on disk but not in the assignment.
unassigned=$(comm -23 <(echo "$actual") <(echo "$assigned"))

# Find files in the assignment but not on disk (stale entries).
stale=$(comm -13 <(echo "$actual") <(echo "$assigned"))

rc=0

if [ -n "$unassigned" ]; then
  echo "ERROR: the following .bats files are not assigned to any shard:" >&2
  echo "$unassigned" | while read -r f; do
    echo "  $f" >&2
  done
  echo "" >&2
  echo "Add each file to .github/bats-shard-assignments.tsv before pushing." >&2
  rc=1
fi

if [ -n "$stale" ]; then
  echo "WARNING: the following files are in the shard assignment but not on disk:" >&2
  echo "$stale" | while read -r f; do
    echo "  $f" >&2
  done
  echo "" >&2
  echo "Remove stale entries from .github/bats-shard-assignments.tsv." >&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  count=$(echo "$assigned" | wc -l | tr -d ' ')
  echo "OK: all $count top-level .bats files are assigned to a shard."
fi

exit "$rc"
