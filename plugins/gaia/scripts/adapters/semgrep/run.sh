#!/usr/bin/env bash
# adapters/semgrep/run.sh — ADR-078 adapter contract for Semgrep.
#
# Contract: run --input <file-list> --config <adapter-config> --output <fragment.json>
#               --runtime-profile {subprocess|container|network} --timeout {seconds}
#
# Phase-5 stub-real implementation: invokes `semgrep --json` against the file list and
# emits a deterministic analysis-results fragment on stdout (or to --output if provided).
# Exit code 0 = ran cleanly, 1 = scanner errored. The probe interprets exit-code semantics.

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
    -h|--help)
      cat <<EOF
adapters/semgrep/run.sh — ADR-078 contract entry for Semgrep.
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

semgrep_args=(--json --quiet)
if [ -n "$CONFIG" ]; then
  semgrep_args+=(--config "$CONFIG")
else
  semgrep_args+=(--config "p/default")
fi

# Read targets from the file-list line by line.
mapfile -t TARGETS < "$INPUT"

if ! command -v semgrep >/dev/null 2>&1; then
  echo "run.sh: semgrep not found on PATH" >&2
  exit 1
fi

raw="$(semgrep "${semgrep_args[@]}" "${TARGETS[@]}" 2>&1)" || rc=$? || true
rc="${rc:-0}"

# Emit a minimal analysis-results-fragment shape: {tool, status, findings: [...]}.
fragment="$(jq -nc \
  --arg tool "semgrep" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{tool: $tool, status: (if $rc == 0 then "passed" else "errored" end), raw: $raw, findings: []}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
