#!/usr/bin/env bash
# refresh-bats-file-timing.sh — Download shard timing artifacts from a CI run
# and merge them into the committed baseline .github/bats-file-timing.tsv.
#
# Each bats-shard job uploads an artifact named shard-N-timing containing
# profiling/shard-N-per-file-timing.tsv (3-column: file<TAB>tests<TAB>wall_seconds
# with a header row). This script downloads those artifacts, keeps the max
# wall_seconds per file across all shards, and writes a 2-column TSV
# (file<TAB>wall_seconds with header) ready to commit.
#
# Usage:
#   refresh-bats-file-timing.sh <run-id> [--repo <owner/repo>]
#
# Requirements: gh (GitHub CLI), sort, awk, tail

set -euo pipefail

usage() {
  echo "Usage: $0 <workflow-run-id> [--repo <owner/repo>]" >&2
  echo "  Downloads shard-*-timing artifacts from the given CI run and" >&2
  echo "  writes .github/bats-file-timing.tsv (2-column: file wall_seconds)." >&2
  exit 1
}

if [ $# -lt 1 ] || [ -z "$1" ]; then
  usage
fi

RUN_ID="$1"
shift

REPO_FLAG=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_FLAG=(--repo "$2"); shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$REPO_ROOT/.github/bats-file-timing.tsv"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading shard timing artifacts from run $RUN_ID..."
gh run download "$RUN_ID" "${REPO_FLAG[@]}" -p 'shard-*-timing' -D "$TMPDIR" 2>&1

# Find all per-file timing TSVs (3-column: file, tests, wall_seconds).
per_file_tsvs=()
while IFS= read -r f; do
  per_file_tsvs+=("$f")
done < <(find "$TMPDIR" -name '*-per-file-timing.tsv' -type f 2>/dev/null)

if [ ${#per_file_tsvs[@]} -eq 0 ]; then
  echo "Error: no per-file timing TSVs found in downloaded artifacts." >&2
  exit 1
fi

echo "Found ${#per_file_tsvs[@]} shard timing file(s)."

# Merge: strip header rows, sort by file then wall_seconds descending,
# deduplicate by file to keep the max, emit 2-column output.
{
  printf 'file\twall_seconds\n'
  for f in "${per_file_tsvs[@]}"; do
    tail -n +2 "$f"
  done | sort -t"$(printf '\t')" -k1,1 -k3,3nr \
       | sort -t"$(printf '\t')" -k1,1 -u \
       | awk -F'\t' '{ print $1 "\t" $3 }'
} > "$OUTPUT"

count=$(tail -n +2 "$OUTPUT" | wc -l | tr -d ' ')
total=$(tail -n +2 "$OUTPUT" | awk -F'\t' '{ s += $2 } END { print s+0 }')
echo "Wrote $OUTPUT: $count files, ${total}s total measured time."
