#!/usr/bin/env bash
# parse-h2-boundaries.sh — code-block-aware H2 boundary detector for gaia-shard-doc.
#
# Reads a Markdown file and emits one line per real H2 boundary in the form:
#
#   <line_number>:<heading_text>
#
# Lines whose first three characters are a backtick fence (```) toggle a
# fenced-code-block state; while inside that state, `## `-prefixed lines are
# ignored. This mirrors the reference implementation in
# `_memory/checkpoints/E53-S222-shard-architecture.py::find_h2_boundaries`,
# which is the canonical byte-identity baseline for AC3 of E53-S236.
#
# Usage:
#   parse-h2-boundaries.sh <markdown_file>
#
# Exit codes:
#   0  success (zero or more boundaries written to stdout)
#   1  usage error
#   2  source file missing or unreadable
#
# Refs: ADR-070, AC1/AC2/AC3/AC4 of E53-S236, E53-S222 finding #4.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'parse-h2-boundaries.sh: usage: %s <markdown_file>\n' "$0" >&2
  exit 1
fi

src="$1"
if [[ ! -r "$src" ]]; then
  printf 'parse-h2-boundaries.sh: cannot read source file: %s\n' "$src" >&2
  exit 2
fi

awk '
  BEGIN { in_code = 0; n = 0 }
  {
    # A line that starts with three backticks toggles fenced-code-block state.
    # The legacy Python uses str.startswith("```"), so any prefix qualifies
    # (with or without a language tag).
    if (substr($0, 1, 3) == "```") {
      in_code = 1 - in_code
      next
    }
    if (in_code) next
    if (substr($0, 1, 3) == "## ") {
      heading = substr($0, 4)
      # Strip trailing CR (Windows line endings) and trailing whitespace.
      sub(/\r$/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      printf "%d:%s\n", NR, heading
      n++
    }
  }
' "$src"
