#!/usr/bin/env bash
# profile-bats-timing.sh — Run bats files individually and record per-file
# wall-clock timing to a TSV artifact.  Used by the CI profiling step to
# measure actual durations and inform shard rebalancing.
#
# Usage:
#   profile-bats-timing.sh [--output FILE] [--shard N] [FILE ...]
#
# When no FILEs are given, profiles every top-level .bats file under
# plugins/gaia/tests/.  With --shard N, profiles only the files assigned
# to shard N in .github/bats-shard-assignments.tsv.
#
# Output (TSV): file  tests  wall_seconds  exit_code
#
# The script exits 0 even if individual bats files fail — the profiling
# artifact records the exit code for each file so the caller can distinguish
# timing data from test failures.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT=""
SHARD=""
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --output)  OUTPUT="$2"; shift 2 ;;
    --shard)   SHARD="$2"; shift 2 ;;
    *)         FILES+=("$1"); shift ;;
  esac
done

OUTPUT="${OUTPUT:-$REPO_ROOT/profiling/bats-timing.tsv}"
mkdir -p "$(dirname "$OUTPUT")"

# Resolve file list.
if [ ${#FILES[@]} -eq 0 ]; then
  if [ -n "$SHARD" ]; then
    while IFS=$'\t' read -r s f _rest; do
      [ "$s" = "$SHARD" ] && FILES+=("$REPO_ROOT/plugins/gaia/tests/$f")
    done < <(grep -v '^#' "$REPO_ROOT/.github/bats-shard-assignments.tsv")
  else
    while IFS= read -r f; do
      FILES+=("$f")
    done < <(find "$REPO_ROOT/plugins/gaia/tests" -maxdepth 1 -name '*.bats' | sort)
  fi
fi

if [ ${#FILES[@]} -eq 0 ]; then
  echo "ERROR: no .bats files to profile" >&2
  exit 1
fi

# Header.
printf 'file\ttests\twall_seconds\texit_code\n' > "$OUTPUT"

total_wall=0
file_count=0

for f in "${FILES[@]}"; do
  bname="$(basename "$f")"
  tests=$(grep -c '^@test ' "$f" 2>/dev/null || echo 0)

  start=$(date +%s)
  rc=0
  bats "$f" >/dev/null 2>&1 || rc=$?
  end=$(date +%s)
  wall=$((end - start))

  printf '%s\t%d\t%d\t%d\n' "$bname" "$tests" "$wall" "$rc" >> "$OUTPUT"
  total_wall=$((total_wall + wall))
  file_count=$((file_count + 1))

  echo "  $bname: ${wall}s ($tests tests, exit $rc)"
done

echo ""
echo "Profiled $file_count files in ${total_wall}s total wall-clock."
echo "Output: $OUTPUT"
