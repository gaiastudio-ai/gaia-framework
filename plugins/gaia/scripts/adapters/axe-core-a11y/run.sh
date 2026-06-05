#!/usr/bin/env bash
# adapters/axe-core-a11y/run.sh — adapter contract for Deque axe-core.
#
# Contract (BOUNDARIES.md):
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#          [--target-url <url>] [--wcag-level <A|AA|AAA>]
#
# Two additive flags beyond the base contract:
#   --target-url <url>       URL to audit (required for an actual run; absence
#                            is permitted for help/dry-run and contract probes)
#   --wcag-level <A|AA|AAA>  WCAG conformance level. Default: AA. Maps to the
#                            axe-core --tags allow-list:
#                              A   -> wcag2a
#                              AA  -> wcag2a,wcag2aa
#                              AAA -> wcag2a,wcag2aa,wcag2aaa
#
# Phase 3A (deterministic): invokes `axe <url> --tags <wcag-tags> --save - --stdout`
# and emits a canonical analysis-results fragment
#   {"name":"axe-core-a11y","status":"passed|errored","findings":[],"raw":"<json-report>"}
# on stdout (or to --output).
#
# Exit codes:
#   0   audit completed
#   1   audit errored (URL unreachable, axe crashed, schema error)
#   127 axe / @axe-core/cli not found on PATH
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
adapters/axe-core-a11y/run.sh — contract entry for Deque axe-core.
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

if ! command -v axe >/dev/null 2>&1; then
  echo "run.sh: axe not found on PATH (npm i -g @axe-core/cli to enable this adapter)" >&2
  exit 127
fi

if [ -z "$TARGET_URL" ]; then
  echo "run.sh: --target-url required for an actual axe-core run" >&2
  exit 1
fi

case "$WCAG_LEVEL" in
  A)   TAGS="wcag2a" ;;
  AA)  TAGS="wcag2a,wcag2aa" ;;
  AAA) TAGS="wcag2a,wcag2aa,wcag2aaa" ;;
  *)
    echo "run.sh: --wcag-level must be one of A, AA, AAA (got '$WCAG_LEVEL')" >&2
    exit 1 ;;
esac

AXE_ARGS=("$TARGET_URL" --tags "$TAGS" --save - --stdout)
if [ -n "$CONFIG" ]; then
  AXE_ARGS+=(--config "$CONFIG")
fi

rc=0
results="$(axe "${AXE_ARGS[@]}" 2>/tmp/axe-stderr-$$)" || rc=$?
err_raw="$(cat /tmp/axe-stderr-$$ 2>/dev/null || true)"
rm -f /tmp/axe-stderr-$$ 2>/dev/null || true

fragment="$(jq -nc \
  --arg name "axe-core-a11y" \
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
