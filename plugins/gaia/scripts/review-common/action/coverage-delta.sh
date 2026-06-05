#!/usr/bin/env bash
# coverage-delta.sh — deterministic coverage-delta computation.
#
# Computes the diff between a baseline and current coverage report and emits
# the result as a JSON fragment for verdict-resolver.sh consumption. Used by
# /gaia-test-automate to gate APPROVE on a non-zero positive coverage delta:
# zero or negative delta yields REQUEST_CHANGES via the verdict resolver.
#
# Public API:
#   coverage-delta.sh --baseline <path> --current <path> [--format <fmt>]
#   coverage-delta.sh --help
#
# Where <fmt> is one of:
#   auto         (default) — sniff format from file content / extension
#   lcov         lcov genhtml-style summary text  (parses 'Lines executed:N%')
#   coveragepy   coverage.py 6.x JSON report      (parses .totals.percent_covered)
#
# Output (stdout, JSON on a single line):
#   {"coverage_delta": <number>, "baseline": <number>, "current": <number>}
#
# Exit codes:
#   0  success — JSON written to stdout
#   1  caller error / unreadable input / parse failure
#
# POSIX discipline: bash 3.2 (macOS), set -euo pipefail, LC_ALL=C, no jq for
# the lcov path. jq is optional and used only for the JSON-format branch.
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="coverage-delta.sh"

err() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }

usage() {
  cat <<EOF
$SCRIPT_NAME — coverage-delta computation for /gaia-test-automate

Usage:
  $SCRIPT_NAME --baseline <path> --current <path> [--format <fmt>]
  $SCRIPT_NAME --help

Required:
  --baseline <path>   Coverage report captured BEFORE generated tests apply
  --current  <path>   Coverage report captured AFTER  generated tests apply

Optional:
  --format <fmt>      auto (default) | lcov | coveragepy
                      auto-detect: file starts with '{' -> coveragepy; else lcov.

Output (stdout, single-line JSON):
  {"coverage_delta": N, "baseline": N, "current": N}

EOF
}

# --- argument parsing ------------------------------------------------

BASELINE=""
CURRENT=""
FORMAT="auto"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --baseline)
      [ "$#" -ge 2 ] || { err "--baseline requires a path"; exit 1; }
      BASELINE="$2"; shift 2 ;;
    --current)
      [ "$#" -ge 2 ] || { err "--current requires a path"; exit 1; }
      CURRENT="$2"; shift 2 ;;
    --format)
      [ "$#" -ge 2 ] || { err "--format requires a value"; exit 1; }
      FORMAT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "unknown argument: $1"; exit 1 ;;
  esac
done

[ -n "$BASELINE" ] || { err "missing required --baseline <path>"; exit 1; }
[ -n "$CURRENT"  ] || { err "missing required --current <path>"; exit 1; }

[ -r "$BASELINE" ] || { err "baseline file not readable: $BASELINE"; exit 1; }
[ -r "$CURRENT"  ] || { err "current file not readable: $CURRENT";  exit 1; }

# --- format auto-detect ---------------------------------------------
# Use the FIRST file's first non-empty character: '{' => coveragepy JSON;
# otherwise treat as lcov summary text.

detect_format() {
  local file="$1"
  local first
  first="$(awk 'NF { sub(/^[[:space:]]+/, ""); print substr($0, 1, 1); exit }' "$file" 2>/dev/null || true)"
  if [ "$first" = "{" ]; then
    printf 'coveragepy'
  else
    printf 'lcov'
  fi
}

if [ "$FORMAT" = "auto" ]; then
  FORMAT="$(detect_format "$BASELINE")"
fi

# --- per-format extractors ------------------------------------------

extract_lcov() {
  # Parse the first 'Lines executed:N%' line. Tolerates whitespace.
  # Returns the percentage as a number on stdout, or empty on failure.
  local file="$1"
  awk -F'[: %]' '
    /^[[:space:]]*Lines executed:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
          print $i; exit
        }
      }
    }
  ' "$file"
}

extract_coveragepy() {
  # Pull .totals.percent_covered. Requires jq.
  local file="$1"
  if ! command -v jq >/dev/null 2>&1; then
    err "jq is required for coveragepy format"
    exit 1
  fi
  jq -r '.totals.percent_covered // empty' "$file" 2>/dev/null
}

extract_pct() {
  local file="$1"
  case "$FORMAT" in
    lcov)        extract_lcov       "$file" ;;
    coveragepy)  extract_coveragepy "$file" ;;
    *) err "unsupported format: $FORMAT"; exit 1 ;;
  esac
}

BASELINE_PCT="$(extract_pct "$BASELINE")"
CURRENT_PCT="$(extract_pct  "$CURRENT")"

if [ -z "$BASELINE_PCT" ]; then
  err "could not parse coverage percentage from baseline: $BASELINE (format=$FORMAT)"
  exit 1
fi
if [ -z "$CURRENT_PCT" ]; then
  err "could not parse coverage percentage from current: $CURRENT (format=$FORMAT)"
  exit 1
fi

# --- compute delta and emit JSON ------------------------------------
# Use awk for portable floating-point arithmetic. macOS bash 3.2 has no
# native float; awk is POSIX and uniformly available.

awk -v b="$BASELINE_PCT" -v c="$CURRENT_PCT" '
BEGIN {
  d = c - b
  printf "{\"coverage_delta\":%g,\"baseline\":%g,\"current\":%g}\n", d, b, c
}
'

exit 0
