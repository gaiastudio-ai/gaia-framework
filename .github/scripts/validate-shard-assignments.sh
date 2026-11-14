#!/usr/bin/env bash
# validate-shard-assignments.sh — CI guard that fails when any top-level
# .bats file under plugins/gaia/tests/ is missing from the shard assignment
# file, or when any shard in the workflow matrix has zero files assigned.
# Forces developers to classify every new test file into a shard.
#
# Exit codes:
#   0 — every .bats file is assigned to exactly one shard; no empty shards
#   1 — one or more files are unassigned, stale, or a shard is empty

set -euo pipefail

REPO_ROOT="${1:-.}"
ASSIGNMENT_FILE="$REPO_ROOT/.github/bats-shard-assignments.tsv"
TESTS_DIR="$REPO_ROOT/plugins/gaia/tests"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/plugin-ci.yml"

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

# ---------------------------------------------------------------------------
# Empty-shard check: read the shard count from the workflow matrix and verify
# every shard 1..N has at least one file assigned.
# ---------------------------------------------------------------------------
n_shards=""
if [ -f "$WORKFLOW_FILE" ]; then
  # Try yq first (handles YAML correctly).
  if command -v yq >/dev/null 2>&1; then
    n_shards=$(yq '.jobs.bats-shard.strategy.matrix.shard | length' "$WORKFLOW_FILE" 2>/dev/null) || n_shards=""
  fi
  # Fallback: grep the shard array line and count comma-separated elements.
  # Works on bash 3.2 and 5 with no external YAML parser.
  if [ -z "$n_shards" ] || [ "$n_shards" = "null" ] || [ "$n_shards" = "0" ]; then
    shard_line=$(grep -E '^\s+shard:\s*\[' "$WORKFLOW_FILE" | head -1) || true
    if [ -n "$shard_line" ]; then
      # Extract the bracket contents and count comma-separated tokens.
      bracket_content="${shard_line#*[}"
      bracket_content="${bracket_content%%]*}"
      # Count elements: split on comma, count non-empty tokens.
      n_shards=0
      IFS=',' read -ra _tokens <<< "$bracket_content"
      for _t in "${_tokens[@]}"; do
        # Trim whitespace.
        _t="${_t## }"
        _t="${_t%% }"
        if [ -n "$_t" ]; then
          n_shards=$((n_shards + 1))
        fi
      done
    fi
  fi
fi

if [ -n "$n_shards" ] && [ "$n_shards" -gt 0 ] 2>/dev/null; then
  # Collect the distinct shards that appear in the assignment file.
  assigned_shards=$(grep -v '^#' "$ASSIGNMENT_FILE" | awk -F'\t' '{print $1}' | sort -u -n)
  s=1
  while [ "$s" -le "$n_shards" ]; do
    if ! echo "$assigned_shards" | grep -qx "$s"; then
      echo "ERROR: shard $s has no files assigned in $ASSIGNMENT_FILE" >&2
      rc=1
    fi
    s=$((s + 1))
  done
fi

if [ "$rc" -eq 0 ]; then
  count=$(echo "$assigned" | wc -l | tr -d ' ')
  echo "OK: all $count top-level .bats files are assigned to a shard."
fi

exit "$rc"
