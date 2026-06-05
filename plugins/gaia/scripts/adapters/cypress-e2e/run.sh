#!/usr/bin/env bash
# adapters/cypress-e2e/run.sh — adapter contract for Cypress e2e runner.
#
# Contract (BOUNDARIES.md):
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#          [--target-url <url>]
#
# The optional --target-url flag is e2e-specific. When provided, it is passed
# via Cypress's --config baseUrl=<url> override so the project's
# cypress.config.{js,ts} default baseUrl is overridden for the run.
# Omission keeps the project default.
#
# Phase 3A (deterministic): invokes `npx cypress run --reporter json`,
# captures the JSON results, and emits a canonical analysis-results fragment
# on stdout (or to --output if provided). Exit code 0 = ran cleanly,
# 1 = runner errored, 127 = npx/cypress not found on PATH. The probe
# interprets exit-code semantics.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT=600
TARGET_URL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --target-url) TARGET_URL="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/cypress-e2e/run.sh — adapter contract entry for Cypress e2e runner.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
         [--target-url <url>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$INPUT" ] && [ ! -r "$INPUT" ]; then
  echo "run.sh: input file not readable: $INPUT" >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "run.sh: npx not found on PATH (install Node.js / npm to enable Cypress)" >&2
  exit 127
fi

CY_ARGS=(cypress run --reporter json)
if [ -n "$CONFIG" ]; then
  CY_ARGS+=(--config-file "$CONFIG")
fi

if [ -n "$TARGET_URL" ]; then
  CY_ARGS+=(--config "baseUrl=$TARGET_URL")
fi

# Run the test suite. Capture stdout (JSON results) separately from stderr.
rc=0
results="$(npx "${CY_ARGS[@]}" 2>/tmp/cypress-e2e-stderr-$$)" || rc=$?
err_raw="$(cat /tmp/cypress-e2e-stderr-$$ 2>/dev/null || true)"
rm -f /tmp/cypress-e2e-stderr-$$ 2>/dev/null || true

fragment="$(jq -nc \
  --arg name "cypress-e2e" \
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
