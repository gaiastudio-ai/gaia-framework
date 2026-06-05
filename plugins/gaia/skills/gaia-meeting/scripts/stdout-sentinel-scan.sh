#!/usr/bin/env bash
# stdout-sentinel-scan.sh — anti-pattern scanner
#
# Scans `/gaia-meeting` SKILL.md yield-boundary procedure sections for two
# stdout-sentinel patterns that were empirically defeated by harness Auto Mode
# on 2026-05-09 (memory rule `feedback_askuserquestion_under_automode.md`):
#
#   1. literal: "<<YIELD-STOP"   (script-side turn-terminal sentinel emitted by yield-gate.sh)
#   2. literal: "<<TURN-END"     (alternate sentinel form used in early drafts)
#
# Both patterns are forbidden inside SKILL.md yield-boundary procedure sections
# because they fail under harness Auto Mode — the harness does not stop on
# stdout content. The substrate-correct primitive is `AskUserQuestion`.
#
# Usage:
#   stdout-sentinel-scan.sh FILE
#
# Exit codes:
#   0 — no violations inside yield-boundary scope
#   1 — at least one violation inside yield-boundary scope
#   2 — usage error (no file specified or file not found)
#
# Output format (one line per (pattern, file, line) tuple):
#   {file}:{line}:{matched-pattern}
#
# Scope-limit rationale:
# A naive `grep <<YIELD-STOP SKILL.md` would trip on documentation references
# (§Critical Rules prohibition prose, §References detail records, change-log
# entries discussing the deprecated mechanism). The scanner MUST
# limit its scope to yield-boundary procedure sections inside SKILL.md so
# legitimate documentation references stay un-flagged.
#
# Scope definition: yield-boundary procedure sections live inside the §Procedure
# section of SKILL.md. The §Procedure region starts at a heading whose body
# matches `Procedure` (case-sensitive ASCII match — never expands across
# unrelated sections like §References) and ends at the next heading at the
# same or shallower depth.
#
# Within §Procedure, every `### Phase N — *` subsection is in scope (these
# are where checkpoint-yield procedures live — `yield-gate.sh` exec calls and
# the literal `<<YIELD-STOP` / `<<TURN-END` sentinels). Headings outside
# §Procedure (e.g., `## Critical Rules`, `## References`, `## Architectural
# Anchors`) are out-of-scope so legitimate documentation references that
# discuss the deprecated mechanism do not trip the check.
#
# Pure deterministic scan; no LLM judgment.
# `awk` for state machine + `grep -F` for literal pattern match.

set -euo pipefail

PROG="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage: $PROG FILE

Scan a SKILL.md file for forbidden stdout-sentinel patterns inside
yield-boundary procedure sections. Exit non-zero on any violation.

Forbidden patterns (literal):
  <<YIELD-STOP
  <<TURN-END

Output format: {file}:{line}:{matched-pattern}
EOF
}

# ---- Parse args -----------------------------------------------------------

if [ $# -lt 1 ] || [ $# -gt 1 ]; then
  usage
  exit 2
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

FILE="$1"

if [ ! -f "$FILE" ]; then
  echo "$PROG: not a file: $FILE" >&2
  exit 2
fi

# ---- Compute in-scope line ranges ------------------------------------------
#
# awk state machine:
#   - emits "{start} {end}" tuples to stdout, one tuple per yield-boundary
#     procedure section.
#   - START: heading line (^#{2,}) whose body matches /[Yy]ield/.
#   - END:   the line BEFORE the next heading line (^#{1,}) at the same OR
#            shallower depth; or EOF if no such heading follows.
#
# We deliberately use the heading depth at START to decide the END boundary
# so an H4 yield-boundary subsection ends at the next H4 / H3 / H2 / H1 — not
# at the next H5 (which would still be inside the same logical section).

RANGES="$(awk '
  function heading_depth(line,    n) {
    n = 0
    while (substr(line, n + 1, 1) == "#") n++
    return n
  }
  /^#+/ {
    cur_depth = heading_depth($0)
    # Closing the current §Procedure scope: any heading at <= scope_depth.
    if (in_scope && cur_depth <= scope_depth) {
      print scope_start, NR - 1
      in_scope = 0
    }
    # Open a new §Procedure scope on a heading whose body matches "Procedure"
    # (whole-word, case-sensitive). Heading depth >= 2 (## or deeper) so we
    # never match an H1 doc title.
    if (!in_scope && cur_depth >= 2 && $0 ~ /(^|[[:space:]])Procedure([[:space:]]|$)/) {
      in_scope    = 1
      scope_depth = cur_depth
      scope_start = NR
    }
    next
  }
  END {
    if (in_scope) print scope_start, NR
  }
' "$FILE")"

if [ -z "$RANGES" ]; then
  # No yield-boundary scope detected — nothing to scan, exit clean.
  exit 0
fi

# ---- Scan in-scope ranges --------------------------------------------------

violations=0

# Build a single awk command that filters in-scope lines and emits
# {line}:{content} tuples; pipe to grep for the forbidden patterns.

while read -r start end; do
  [ -z "$start" ] && continue

  # Extract the in-scope line range with line numbers preserved.
  in_scope_block="$(awk -v s="$start" -v e="$end" 'NR >= s && NR <= e { printf "%d:%s\n", NR, $0 }' "$FILE")"

  # Pattern 1 — literal "<<YIELD-STOP"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lineno="${line%%:*}"
    printf '%s:%s:%s\n' "$FILE" "$lineno" "<<YIELD-STOP"
    violations=$((violations + 1))
  done < <(printf '%s\n' "$in_scope_block" | grep -F "<<YIELD-STOP" 2>/dev/null || true)

  # Pattern 2 — literal "<<TURN-END"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lineno="${line%%:*}"
    printf '%s:%s:%s\n' "$FILE" "$lineno" "<<TURN-END"
    violations=$((violations + 1))
  done < <(printf '%s\n' "$in_scope_block" | grep -F "<<TURN-END" 2>/dev/null || true)
done <<< "$RANGES"

if [ "$violations" -gt 0 ]; then
  exit 1
fi
exit 0
