#!/usr/bin/env bash
# adapters/playwright-e2e/run.sh — ADR-078 adapter contract for Playwright e2e runner.
#
# Contract (ADR-078 / BOUNDARIES.md):
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#          [--target-url <url>]
#
# Story E73-S1 augments the canonical contract with the optional --target-url
# flag (e2e-specific). When provided, it is exported as PLAYWRIGHT_BASE_URL so
# that Playwright's `use: { baseURL: process.env.PLAYWRIGHT_BASE_URL }` config
# pattern picks it up. Omission keeps the project's default config behaviour.
#
# Phase 3A (deterministic): invokes `npx playwright test --reporter=json`,
# captures the JSON results, and emits a canonical analysis-results fragment
# on stdout (or to --output if provided). Exit code 0 = ran cleanly,
# 1 = runner errored, 127 = npx/playwright not found on PATH. The probe
# interprets exit-code semantics.
#
# Refs: ADR-078 §1, FR-RSV2-31, NFR-RSV2-7, story E73-S1.

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
adapters/playwright-e2e/run.sh — ADR-078 contract entry for Playwright e2e runner.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
         [--target-url <url>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --input is part of the canonical contract; for project-scope adapters the
# file list is informational (Playwright runs the full project test suite via
# the playwright config).
if [ -n "$INPUT" ] && [ ! -r "$INPUT" ]; then
  echo "run.sh: input file not readable: $INPUT" >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "run.sh: npx not found on PATH (install Node.js / npm to enable Playwright)" >&2
  # Exit 127 surfaces unavailability when run.sh is invoked directly. The
  # probe's `command -v <provider>` check classifies this as
  # expected_and_missing before run.sh is ever invoked.
  exit 127
fi

PW_ARGS=(playwright test --reporter=json)
if [ -n "$CONFIG" ]; then
  PW_ARGS+=(--config "$CONFIG")
fi

if [ -n "$TARGET_URL" ]; then
  export PLAYWRIGHT_BASE_URL="$TARGET_URL"
fi

# Run the test suite. Capture stdout (JSON results) separately from stderr so
# the analysis-results fragment carries clean JSON.
rc=0
results="$(npx "${PW_ARGS[@]}" 2>/tmp/playwright-e2e-stderr-$$)" || rc=$?
err_raw="$(cat /tmp/playwright-e2e-stderr-$$ 2>/dev/null || true)"
rm -f /tmp/playwright-e2e-stderr-$$ 2>/dev/null || true

# Emit canonical analysis-results fragment shape per E70-S1 run-contract.md §2.1:
# {"name": <adapter>, "status": <passed|errored>, "findings": [...]}.
# Findings shape conforms to checks[].findings[] in analysis-results.schema.json.
fragment="$(jq -nc \
  --arg name "playwright-e2e" \
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
