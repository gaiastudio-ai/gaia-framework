#!/usr/bin/env bash
# adapters/gocyclo/run.sh — ADR-078 adapter contract for gocyclo.
set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""; CONFIG=""; OUTPUT=""; RUNTIME_PROFILE="subprocess"; TIMEOUT=120
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) echo "adapters/gocyclo/run.sh — ADR-078 contract for gocyclo"; exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

if ! command -v gocyclo >/dev/null 2>&1; then
  echo "run.sh: gocyclo not found on PATH" >&2
  # Exit 127 = unavailable per E70-S2 AC10 (distinct from generic error 1).
  exit 127
fi

mapfile -t TARGETS < "$INPUT"
raw="$(gocyclo "${TARGETS[@]}" 2>&1)" || rc=$? || true
rc="${rc:-0}"

# Canonical fragment shape per E70-S1 run-contract.md §2.1: {name, status, findings}.
fragment="$(jq -nc \
  --arg name "gocyclo" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi
exit "$rc"
