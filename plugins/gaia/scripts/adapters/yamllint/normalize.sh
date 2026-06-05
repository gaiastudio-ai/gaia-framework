#!/usr/bin/env bash
# adapters/yamllint/normalize.sh — canonical adapter normalizer for yamllint.
#
# Reads the raw run.sh fragment on stdin (an analysis-results object with
# `findings: [{rule, severity, file, line, message, blocking}, ...]`) and
# emits the canonical normalized findings JSON array on stdout:
#
#   [ { rule, severity, file, line, message }, ... ]
#
# The normalized form drops the `blocking` flag and the wrapper
# `{name, status}` envelope. Empty input yields `[]`.

set -euo pipefail
LC_ALL=C
export LC_ALL

command -v jq >/dev/null 2>&1 || { echo "normalize.sh: jq is required but not on PATH" >&2; exit 1; }

input="$(cat)"

if [ -z "$input" ]; then
  printf '%s\n' '[]'
  exit 0
fi

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
