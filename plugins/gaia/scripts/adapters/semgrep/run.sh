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
# AF-2026-05-31-1 / Test12 F-06: bash 3.2-compat replacement for mapfile.
TARGETS=()
while IFS= read -r _line; do [ -n "$_line" ] && TARGETS+=("$_line"); done < "$INPUT"

if ! command -v semgrep >/dev/null 2>&1; then
  echo "run.sh: semgrep not found on PATH" >&2
  # Exit 127 = unavailable (distinct from generic error 1) per E70-S2 AC10.
  # The probe still classifies this via its own command -v check before invoking
  # run.sh; this exit code surfaces unavailability when run.sh is invoked directly.
  exit 127
fi

raw="$(semgrep "${semgrep_args[@]}" "${TARGETS[@]}" 2>&1)" || rc=$? || true
rc="${rc:-0}"

# Emit canonical analysis-results fragment shape per E70-S1 run-contract.md §2.1:
# {"name": <adapter>, "status": <passed|errored>, "findings": [...]}.
# Findings shape conforms to checks[].findings[] in analysis-results.schema.json.
fragment="$(jq -nc \
  --arg name "semgrep" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
