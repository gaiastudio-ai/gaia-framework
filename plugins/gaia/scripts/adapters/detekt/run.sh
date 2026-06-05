#!/usr/bin/env bash
# adapters/detekt/run.sh — adapter contract for Detekt.
# Invokes `detekt --report json:<tmp>` against the file list and emits a
# canonical analysis-results fragment.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT=300

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) echo "Usage: run.sh --input <file-list> [--config <path>] [--output <path>] [--timeout <seconds>]"; exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

if ! command -v detekt >/dev/null 2>&1; then
  echo "run.sh: detekt not found on PATH" >&2
  exit 127
fi

TARGETS=()
while IFS= read -r _line || [ -n "$_line" ]; do
  [ -n "$_line" ] && TARGETS+=("$_line")
done < "$INPUT"
report_tmp="$(mktemp)"
trap 'rm -f "$report_tmp"' EXIT

input_csv=""
if [ "${#TARGETS[@]}" -gt 0 ]; then
  input_csv="$(IFS=,; echo "${TARGETS[*]}")"
fi
args=(--report "json:$report_tmp")
if [ -n "$CONFIG" ]; then args+=(--config "$CONFIG"); fi
if [ -n "$input_csv" ]; then args+=(--input "$input_csv"); fi

raw=""
rc=0
raw="$(detekt "${args[@]}" 2>&1)" || rc=$?

fragment="$(jq -nc \
  --arg name "detekt" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
