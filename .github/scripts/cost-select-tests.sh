#!/usr/bin/env bash
# cost-select-tests.sh — Select test files by measured cost to fit a time budget.
#
# Reads a committed timing baseline (2-column TSV: file<TAB>wall_seconds) and
# a list of candidate test files (one per line on stdin), then prints the files
# that fit within the budget sorted by ascending cost.
#
# Exit codes:
#   0  Files selected (printed to stdout) or graceful skip (see below).
#   1  Usage error.
#
# When no files fit the budget or the baseline is unavailable, the script
# prints a notice to stderr and exits 0 with no stdout output — the caller
# should check whether stdout is empty and skip the bats run.
#
# Usage:
#   echo "$candidate_files" | cost-select-tests.sh <baseline.tsv> [budget_seconds]
#
# Output on stdout: selected file paths, one per line.
# Output on stderr: structured log lines (counts, costs, fallback).

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <baseline.tsv> [budget_seconds]" >&2
  exit 1
fi

BASELINE="$1"
BUDGET="${2:-240}"

# ── Load baseline ──────────────────────────────────────────────────────────
if [ ! -r "$BASELINE" ]; then
  echo "NOTICE: timing baseline unavailable; skipping fast-feedback." >&2
  exit 0
fi

# ── Compute fallback: median of known times, floor 4s ──────────────────────
fallback=4
if [ "$(tail -n +2 "$BASELINE" | wc -l | tr -d ' ')" -gt 0 ]; then
  sorted_times=$(tail -n +2 "$BASELINE" | awk -F'\t' '{ print $2 }' | sort -n)
  n=$(echo "$sorted_times" | wc -l | tr -d ' ')
  mid=$(( (n + 1) / 2 ))
  med=$(echo "$sorted_times" | sed -n "${mid}p")
  if [ "${med:-0}" -gt "$fallback" ] 2>/dev/null; then
    fallback="$med"
  fi
fi

# ── Read candidates from stdin ─────────────────────────────────────────────
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

candidates_file="$tmpdir/candidates"
cat > "$candidates_file"

if [ ! -s "$candidates_file" ]; then
  exit 0
fi

# ── Build cost list using awk to look up each candidate in the baseline ────
# Produces: cost<TAB>filepath lines.
awk -F'\t' '
  NR == FNR && FNR > 1 { cost[$1] = $2; next }
  NR != FNR {
    if ($0 == "") next
    # Extract basename for lookup.
    bname = $0
    gsub(/.*\//, "", bname)
    c = (bname in cost) ? cost[bname] : "'"$fallback"'"
    print c "\t" $0
  }
' "$BASELINE" "$candidates_file" | sort -t"$(printf '\t')" -k1,1n > "$tmpdir/sorted"

# ── Select within budget ──────────────────────────────────────────────────
included_count=0
included_cost=0
dropped_count=0
dropped_cost=0

while IFS=$'\t' read -r cost file; do
  [ -z "$file" ] && continue
  new_total=$((included_cost + cost))
  if [ "$new_total" -le "$BUDGET" ]; then
    echo "$file"
    included_count=$((included_count + 1))
    included_cost=$new_total
  else
    dropped_count=$((dropped_count + 1))
    dropped_cost=$((dropped_cost + cost))
  fi
done < "$tmpdir/sorted" > "$tmpdir/included"

# ── Zero-fit guard ─────────────────────────────────────────────────────────
if [ "$included_count" -eq 0 ]; then
  echo "NOTICE: no files fit the fast-feedback budget (${BUDGET}s); full shards will cover them." >&2
  exit 0
fi

# ── Report on stderr, selected files on stdout ─────────────────────────────
echo "SELECTED: ${included_count} files (~${included_cost}s), DROPPED: ${dropped_count} files (~${dropped_cost}s), FALLBACK: ${fallback}s" >&2
cat "$tmpdir/included"
