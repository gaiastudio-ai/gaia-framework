#!/usr/bin/env bash
# adapters/eslint-plugin-sonarjs/run.sh — ADR-078 adapter contract for ESLint + sonarjs plugin.
set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""; CONFIG=""; OUTPUT=""; RUNTIME_PROFILE="subprocess"; TIMEOUT=180
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) echo "adapters/eslint-plugin-sonarjs/run.sh — ADR-078 contract"; exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

if ! command -v eslint >/dev/null 2>&1; then
  echo "run.sh: eslint not found on PATH" >&2
  exit 1
fi

mapfile -t TARGETS < "$INPUT"
eslint_args=(--format json)
if [ -n "$CONFIG" ]; then
  eslint_args+=(--config "$CONFIG")
fi

raw="$(eslint "${eslint_args[@]}" "${TARGETS[@]}" 2>&1)" || rc=$? || true
rc="${rc:-0}"

fragment="$(jq -nc \
  --arg tool "eslint-plugin-sonarjs" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{tool: $tool, status: (if $rc == 0 then "passed" else "errored" end), raw: $raw, findings: []}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi
exit "$rc"
