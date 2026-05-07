#!/usr/bin/env bash
# adapters/plugin-manifest-validator/normalize.sh — FR-410 + ADR-078 (AC6).
#
# Reads the raw run.sh fragment on stdin (an analysis-results object with
# `findings: [{rule, severity, file, line, message, blocking}, ...]`) and
# emits the canonical normalized findings JSON array on stdout:
#
#   [ { rule, severity, file, line, message }, ... ]
#
# The normalized form intentionally drops the `blocking` flag and the wrapper
# `{name, status}` envelope. Downstream consumers that need the envelope can
# read run.sh stdout directly; this normalizer is the projection used by
# review-pipeline aggregators that only care about findings rows.

set -euo pipefail
LC_ALL=C
export LC_ALL

command -v jq >/dev/null 2>&1 || { echo "normalize.sh: jq is required but not on PATH" >&2; exit 1; }

# Read all of stdin into a single jq invocation. `jq -e` returns non-zero when
# the filter produces null/false; using `jq -c` (no -e) keeps the contract that
# valid input always yields a JSON array on stdout.
input="$(cat)"

if [ -z "$input" ]; then
  printf '%s\n' '[]'
  exit 0
fi

# Project to {rule, severity, file, line, message}. Missing fields default to
# safe values per the canonical analysis-results.schema.json.
printf '%s' "$input" | jq -c '
  (.findings // [])
  | map({
      rule: (.rule // ""),
      severity: (.severity // "info"),
      file: (.file // ""),
      line: (.line // 0),
      message: (.message // "")
    })
'
