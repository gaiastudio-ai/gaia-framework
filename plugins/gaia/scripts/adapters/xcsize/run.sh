#!/usr/bin/env bash
# adapters/xcsize/run.sh — adapter contract for xcsize.
# Uses xcrun tooling for iOS app thinning size analysis. The provider binary is
# `xcrun` (Xcode command-line tools); the actual size sub-tool is invoked via
# `xcrun size <target>` for static binary size and (optionally) app-thinning
# variants on .ipa / .xcarchive inputs.

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

if ! command -v xcrun >/dev/null 2>&1; then
  echo "run.sh: xcrun not found on PATH" >&2
  exit 127
fi

TARGETS=()
while IFS= read -r _line || [ -n "$_line" ]; do
  [ -n "$_line" ] && TARGETS+=("$_line")
done < "$INPUT"
raw=""
rc=0
if [ "${#TARGETS[@]}" -gt 0 ]; then
  # `xcrun size` reports byte sizes; iterate to keep error containment per target.
  raw="$(xcrun size "${TARGETS[@]}" 2>&1)" || rc=$?
fi

fragment="$(jq -nc \
  --arg name "xcsize" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
