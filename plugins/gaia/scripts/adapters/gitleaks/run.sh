#!/usr/bin/env bash
# adapters/gitleaks/run.sh — ADR-078 adapter contract for Gitleaks.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT=180

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/gitleaks/run.sh — ADR-078 contract entry for Gitleaks.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "run.sh: gitleaks not found on PATH" >&2
  # Exit 127 = unavailable per E70-S2 AC10 (distinct from generic error 1).
  exit 127
fi

gitleaks_args=(detect --no-git --report-format json --report-path -)
if [ -n "$CONFIG" ]; then
  gitleaks_args+=(--config "$CONFIG")
fi

raw="$(gitleaks "${gitleaks_args[@]}" 2>&1)" || rc=$? || true
rc="${rc:-0}"

# Canonical fragment shape per E70-S1 run-contract.md §2.1: {name, status, findings}.
fragment="$(jq -nc \
  --arg name "gitleaks" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
