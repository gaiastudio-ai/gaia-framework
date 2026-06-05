#!/usr/bin/env bash
# adapters/lighthouse-a11y/run.sh — adapter contract for Lighthouse a11y.
#
# Contract (BOUNDARIES.md):
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#          [--target-url <url>] [--wcag-level <A|AA|AAA>] [--categories <csv>]
#
# Three additive flags beyond the base contract:
#   --target-url <url>       URL to audit (required for an actual run; absence
#                            is permitted for help/dry-run and contract probes)
#   --wcag-level <A|AA|AAA>  WCAG conformance level. Default: AA. Recorded in the
#                            output fragment for the WCAG rubric judgment but
#                            not directly consumed by Lighthouse — Lighthouse
#                            audits against the full a11y category and the rubric
#                            loader filters by level.
#   --categories <csv>       Lighthouse categories to run. Default: "accessibility".
#                            Should remain "accessibility" for /gaia-test-a11y.
#
# Phase 3A (deterministic): invokes `lighthouse <url> --output=json --quiet
# --only-categories=accessibility` and emits a canonical analysis-results
# fragment {"name":"lighthouse-a11y","status":"passed|errored","findings":[],
# "raw":"<json-report>"} on stdout (or to --output).
#
# Exit codes:
#   0   audit completed
#   1   audit errored (URL unreachable, Chrome crash, schema error)
#   127 lighthouse not found on PATH
#
# POSIX discipline: bash 3.2 / macOS-compatible, set -euo pipefail, LC_ALL=C.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT=120
TARGET_URL=""
WCAG_LEVEL="AA"
CATEGORIES="accessibility"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --target-url) TARGET_URL="$2"; shift 2 ;;
    --wcag-level) WCAG_LEVEL="$2"; shift 2 ;;
    --categories) CATEGORIES="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/lighthouse-a11y/run.sh — contract entry for Lighthouse a11y.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
         [--target-url <url>] [--wcag-level <A|AA|AAA>] [--categories <csv>]
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
  echo "run.sh: --target-url required for an actual lighthouse-a11y run" >&2
  exit 1
fi

case "$WCAG_LEVEL" in
  A|AA|AAA) ;;
  *)
    echo "run.sh: --wcag-level must be one of A, AA, AAA (got '$WCAG_LEVEL')" >&2
    exit 1 ;;
esac

LH_ARGS=("$TARGET_URL" --output=json --quiet --chrome-flags="--headless --no-sandbox" "--only-categories=$CATEGORIES")
if [ -n "$CONFIG" ]; then
  LH_ARGS+=(--config-path "$CONFIG")
fi

rc=0
results="$(lighthouse "${LH_ARGS[@]}" 2>/tmp/lighthouse-a11y-stderr-$$)" || rc=$?
err_raw="$(cat /tmp/lighthouse-a11y-stderr-$$ 2>/dev/null || true)"
rm -f /tmp/lighthouse-a11y-stderr-$$ 2>/dev/null || true

fragment="$(jq -nc \
  --arg name "lighthouse-a11y" \
  --argjson rc "$rc" \
  --arg raw "$results" \
  --arg err "$err_raw" \
  --arg level "$WCAG_LEVEL" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw, wcag_level: $level, error_detail: (if $rc == 0 then null else $err end)}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
