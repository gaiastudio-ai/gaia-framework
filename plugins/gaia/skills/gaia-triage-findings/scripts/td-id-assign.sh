#!/usr/bin/env bash
# td-id-assign.sh — stable TD-{N} ID assignment
#
# Scans the previous tech-debt-dashboard.md for existing TD-{N} identifiers and
# emits either:
#   --count <n>   — the next N sequential TD-{N} IDs after the highest existing
#   --next-id     — the single next TD-{N} ID after the highest existing
#
# When no prior dashboard exists (file is missing), the sequence starts at TD-1.
# This preserves the legacy critical rule: TD-{N} IDs are stable across runs —
# never renumber.
#
# Usage:
#   td-id-assign.sh --dashboard <path> --count <n>
#   td-id-assign.sh --dashboard <path> --next-id
#
# Output (count form):
#   TD-<n>        (one per line)
# Output (next-id form):
#   TD-<n>        (single line)
#
# Exit codes:
#   0 — emission complete
#   1 — usage error

set -euo pipefail
LC_ALL=C
export LC_ALL

usage() {
  cat >&2 <<EOF
Usage:
  td-id-assign.sh --dashboard <path> --count <n>
  td-id-assign.sh --dashboard <path> --next-id

Scans <path> for TD-{N} tokens and emits the next sequential ID(s). If the
dashboard file does not exist, the sequence starts at TD-1.
EOF
  exit 1
}

DASH=""
COUNT=""
NEXT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dashboard)
      shift
      [ -n "${1:-}" ] || usage
      DASH="$1"
      shift
      ;;
    --count)
      shift
      [ -n "${1:-}" ] || usage
      COUNT="$1"
      shift
      ;;
    --next-id)
      NEXT=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      printf 'td-id-assign.sh: unknown arg: %s\n' "$1" >&2
      usage
      ;;
  esac
done

[ -n "$DASH" ] || usage
if [ -z "$COUNT" ] && [ "$NEXT" -eq 0 ]; then
  usage
fi
if [ -n "$COUNT" ] && [ "$NEXT" -eq 1 ]; then
  printf 'td-id-assign.sh: --count and --next-id are mutually exclusive\n' >&2
  exit 1
fi

# Scan the dashboard for TD-{N} tokens. Missing file is a valid empty state.
highest=0
if [ -f "$DASH" ]; then
  # Extract all TD-{digits} occurrences, pick the numeric max
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ "$n" -gt "$highest" ] 2>/dev/null; then
      highest="$n"
    fi
  done < <(grep -oE 'TD-[0-9]+' "$DASH" 2>/dev/null | sed 's/^TD-//' | sort -n | uniq)
fi

start=$((highest + 1))

if [ "$NEXT" -eq 1 ]; then
  printf 'TD-%d\n' "$start"
  exit 0
fi

# Emit COUNT sequential IDs
i=0
while [ "$i" -lt "$COUNT" ]; do
  printf 'TD-%d\n' "$((start + i))"
  i=$((i + 1))
done

exit 0
