#!/usr/bin/env bash
# adapters/k6/run.sh — ADR-078 adapter contract for k6 load/perf tool.
#
# Contract (ADR-078 / BOUNDARIES.md):
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#          [--target-url <url>] [--script <k6-script-path>]
#
# Story E73-S2 augments the canonical contract with two additive flags:
#   --target-url <url>          BASE URL for the test (exported as K6_TARGET_URL)
#   --script <path>             path to the k6 script (default: $K6_SCRIPT or
#                               .gaia/perf-scripts/default.js)
#
# Phase 3A (deterministic): invokes `k6 run --quiet --summary-export=-`,
# captures the JSON summary on stdout, and emits a canonical analysis-results
# fragment {"name": "k6", "status": "passed|errored", "findings": [],
# "raw": "<summary-json>"} on stdout (or to --output if provided).
#
# Exit codes:
#   0   k6 ran cleanly (load test completed; SLO outcomes are evaluated
#       downstream by the skill's slo-check.sh — k6's own --threshold
#       failures still propagate via $rc when configured in the script)
#   1   k6 errored (script syntax, network failure, timeout)
#   127 k6 not found on PATH (probe interprets as expected_and_missing)
#
# Refs: ADR-078 §1, FR-RSV2-32, NFR-RSV2-7, story E73-S2.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT=300
TARGET_URL=""
SCRIPT_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --target-url) TARGET_URL="$2"; shift 2 ;;
    --script) SCRIPT_PATH="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/k6/run.sh — ADR-078 contract entry for k6.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
         [--target-url <url>] [--script <k6-script-path>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$INPUT" ] && [ ! -r "$INPUT" ]; then
  echo "run.sh: input file not readable: $INPUT" >&2
  exit 1
fi

if ! command -v k6 >/dev/null 2>&1; then
  echo "run.sh: k6 not found on PATH (install k6 from https://k6.io to enable this adapter)" >&2
  exit 127
fi

# Resolve the k6 script. Priority: --script > $K6_SCRIPT > .gaia/perf-scripts/default.js
if [ -z "$SCRIPT_PATH" ]; then
  SCRIPT_PATH="${K6_SCRIPT:-.gaia/perf-scripts/default.js}"
fi
if [ ! -r "$SCRIPT_PATH" ]; then
  echo "run.sh: k6 script not readable: $SCRIPT_PATH (set --script or K6_SCRIPT)" >&2
  exit 1
fi

if [ -n "$TARGET_URL" ]; then
  export K6_TARGET_URL="$TARGET_URL"
fi

K6_ARGS=(run --quiet --summary-export=-)
if [ -n "$CONFIG" ]; then
  K6_ARGS+=(--config "$CONFIG")
fi
K6_ARGS+=("$SCRIPT_PATH")

rc=0
results="$(k6 "${K6_ARGS[@]}" 2>/tmp/k6-stderr-$$)" || rc=$?
err_raw="$(cat /tmp/k6-stderr-$$ 2>/dev/null || true)"
rm -f /tmp/k6-stderr-$$ 2>/dev/null || true

fragment="$(jq -nc \
  --arg name "k6" \
  --argjson rc "$rc" \
  --arg raw "$results" \
  --arg err "$err_raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw, error_detail: (if $rc == 0 then null else $err end)}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
