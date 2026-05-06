#!/usr/bin/env bash
# adapters/lighthouse/run.sh — ADR-078 adapter contract for Google Lighthouse.
#
# Contract (ADR-078 / BOUNDARIES.md):
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#          [--target-url <url>] [--categories <csv>]
#
# Story E73-S2 augments the canonical contract with two additive flags:
#   --target-url <url>       URL to audit (required for an actual run; absence
#                            is permitted for help/dry-run and contract probes)
#   --categories <csv>       Lighthouse categories to run. Default: "performance".
#                            Values: performance, accessibility, best-practices,
#                            seo, pwa.
#
# Phase 3A (deterministic): invokes `lighthouse <url> --output=json --quiet
# --chrome-flags="--headless" --only-categories=<csv>` and emits a canonical
# analysis-results fragment {"name": "lighthouse", "status": "passed|errored",
# "findings": [], "raw": "<json-report>"} on stdout (or to --output).
#
# Exit codes:
#   0   audit completed
#   1   audit errored (URL unreachable, Chrome crash, schema error)
#   127 lighthouse not found on PATH
#
# Refs: ADR-078 §1, FR-RSV2-32, NFR-RSV2-7, story E73-S2.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT=120
TARGET_URL=""
CATEGORIES="performance"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --target-url) TARGET_URL="$2"; shift 2 ;;
    --categories) CATEGORIES="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/lighthouse/run.sh — ADR-078 contract entry for Lighthouse.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
         [--target-url <url>] [--categories <csv>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$INPUT" ] && [ ! -r "$INPUT" ]; then
  echo "run.sh: input file not readable: $INPUT" >&2
  exit 1
fi

if ! command -v lighthouse >/dev/null 2>&1; then
  echo "run.sh: lighthouse not found on PATH (npm i -g lighthouse to enable this adapter)" >&2
  exit 127
fi

if [ -z "$TARGET_URL" ]; then
  echo "run.sh: --target-url required for an actual lighthouse run" >&2
  exit 1
fi

LH_ARGS=("$TARGET_URL" --output=json --quiet --chrome-flags="--headless --no-sandbox" "--only-categories=$CATEGORIES")
if [ -n "$CONFIG" ]; then
  LH_ARGS+=(--config-path "$CONFIG")
fi

rc=0
results="$(lighthouse "${LH_ARGS[@]}" 2>/tmp/lighthouse-stderr-$$)" || rc=$?
err_raw="$(cat /tmp/lighthouse-stderr-$$ 2>/dev/null || true)"
rm -f /tmp/lighthouse-stderr-$$ 2>/dev/null || true

fragment="$(jq -nc \
  --arg name "lighthouse" \
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
