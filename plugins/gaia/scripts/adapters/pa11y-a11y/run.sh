#!/usr/bin/env bash
# adapters/pa11y-a11y/run.sh — adapter contract for pa11y.
#
# Contract (BOUNDARIES.md):
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#          [--target-url <url>] [--wcag-level <A|AA|AAA>]
#
# This adapter augments the canonical contract with two additive flags:
#   --target-url <url>       URL to audit (required for an actual run; absence
#                            is permitted for help/dry-run and contract probes)
#   --wcag-level <A|AA|AAA>  WCAG conformance level. Default: AA. Maps to the
#                            pa11y --standard flag:
#                              A   -> WCAG2A
#                              AA  -> WCAG2AA
#                              AAA -> WCAG2AAA
#
# Phase 3A (deterministic): invokes `pa11y --reporter json --standard <std> <url>`
# and emits a canonical analysis-results fragment
#   {"name":"pa11y-a11y","status":"passed|errored","findings":[],"raw":"<json-report>"}
# on stdout (or to --output).
#
# Exit codes:
#   0   audit completed (pa11y exits 0 even on findings; status reflects audit health)
#   1   audit errored (URL unreachable, headless Chromium crash, schema error)
#   127 pa11y not found on PATH
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --target-url) TARGET_URL="$2"; shift 2 ;;
    --wcag-level) WCAG_LEVEL="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/pa11y-a11y/run.sh — contract entry for pa11y.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
         [--target-url <url>] [--wcag-level <A|AA|AAA>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$INPUT" ] && [ ! -r "$INPUT" ]; then
  echo "run.sh: input file not readable: $INPUT" >&2
  exit 1
fi

if ! command -v pa11y >/dev/null 2>&1; then
  echo "run.sh: pa11y not found on PATH (npm i -g pa11y to enable this adapter)" >&2
  exit 127
fi

if [ -z "$TARGET_URL" ]; then
  echo "run.sh: --target-url required for an actual pa11y run" >&2
  exit 1
fi

case "$WCAG_LEVEL" in
  A)   STD="WCAG2A" ;;
  AA)  STD="WCAG2AA" ;;
  AAA) STD="WCAG2AAA" ;;
  *)
    echo "run.sh: --wcag-level must be one of A, AA, AAA (got '$WCAG_LEVEL')" >&2
    exit 1 ;;
esac

PA_ARGS=(--reporter json --standard "$STD" "$TARGET_URL")
if [ -n "$CONFIG" ]; then
  PA_ARGS=(--config "$CONFIG" "${PA_ARGS[@]}")
fi

rc=0
results="$(pa11y "${PA_ARGS[@]}" 2>/tmp/pa11y-stderr-$$)" || rc=$?
err_raw="$(cat /tmp/pa11y-stderr-$$ 2>/dev/null || true)"
rm -f /tmp/pa11y-stderr-$$ 2>/dev/null || true

# pa11y returns non-zero on findings (exit 2). Treat exit 2 as "passed audit
# with findings" and only flag genuine errors (exit >=3 or exit 1) as errored.
status="passed"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  status="errored"
fi

fragment="$(jq -nc \
  --arg name "pa11y-a11y" \
  --arg status "$status" \
  --arg raw "$results" \
  --arg err "$err_raw" \
  '{name: $name, status: $status, findings: [], raw: $raw, error_detail: (if $status == "passed" then null else $err end)}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

# Normalize: pa11y exit 2 (findings present) is a successful audit run.
if [ "$rc" -eq 2 ]; then
  rc=0
fi

exit "$rc"
