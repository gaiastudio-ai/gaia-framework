#!/usr/bin/env bash
# review-gate-table.sh — shared dual-shape parser for Review Gate table rows
#
# Sourceable library. Provides parse_review_gate_row() which accepts a single
# pipe-delimited markdown table row and returns structured key=value output.
#
# Supports two table shapes:
#   Three-column (legacy):  | Review | Status | Report |
#   Four-column (current):  | Review | Status | Report | Reviewed SHA |
#
# A three-column row is read as reviewed_sha=absent (stale). A four-column
# row includes the SHA. Rows with fewer than 3 or more than 4 data columns
# are rejected.
#
# POSIX discipline: bash 3.2 compatible. No associative arrays, no mapfile,
# no ${x,,}. Uses only bash builtins and printf.
#
# Usage:
#   source scripts/lib/review-gate-table.sh
#   result="$(parse_review_gate_row "| Code Review | PASSED | report.md |")"
#   result="$(parse_review_gate_row "| Code Review | PASSED | report.md | abc123 |")"

# Guard against double-sourcing.
if [ "${_REVIEW_GATE_TABLE_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_REVIEW_GATE_TABLE_LOADED=1

# parse_review_gate_row ROW
#
# Parse a single pipe-delimited table row. Outputs key=value pairs on
# separate lines:
#   gate=<name>
#   status=<verdict>
#   report=<path>
#   reviewed_sha=<sha|absent>
#
# Exit codes:
#   0 — success
#   1 — malformed row (too few or too many columns)
parse_review_gate_row() {
  local row="$1"

  # Strip leading/trailing whitespace.
  local stripped="$row"
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"

  # Strip leading and trailing pipes.
  stripped="${stripped#|}"
  stripped="${stripped%|}"

  # Split on pipe. Use a portable approach (no mapfile).
  local IFS='|'
  # shellcheck disable=SC2206
  local cells=( $stripped )

  local count="${#cells[@]}"
  if [ "$count" -lt 3 ]; then
    printf 'review-gate-table.sh: malformed row: fewer than 3 columns\n' >&2
    return 1
  fi
  if [ "$count" -gt 4 ]; then
    printf 'review-gate-table.sh: malformed row: more than 4 columns\n' >&2
    return 1
  fi

  # Trim whitespace from each cell.
  local gate status report sha

  gate="${cells[0]}"
  gate="${gate#"${gate%%[![:space:]]*}"}"
  gate="${gate%"${gate##*[![:space:]]}"}"

  status="${cells[1]}"
  status="${status#"${status%%[![:space:]]*}"}"
  status="${status%"${status##*[![:space:]]}"}"

  report="${cells[2]}"
  report="${report#"${report%%[![:space:]]*}"}"
  report="${report%"${report##*[![:space:]]}"}"

  if [ "$count" -ge 4 ]; then
    sha="${cells[3]}"
    sha="${sha#"${sha%%[![:space:]]*}"}"
    sha="${sha%"${sha##*[![:space:]]}"}"
    # Empty fourth column still means absent
    if [ -z "$sha" ]; then
      sha="absent"
    fi
  else
    sha="absent"
  fi

  printf 'gate=%s\n' "$gate"
  printf 'status=%s\n' "$status"
  printf 'report=%s\n' "$report"
  printf 'reviewed_sha=%s\n' "$sha"
  return 0
}

# parse_review_gate_table FILE
#
# Parse all data rows from the Review Gate table in FILE. Emits TSV lines:
#   GATE\tSTATUS\tREPORT\tSHA
#
# Detects three-column and four-column tables. Three-column rows get
# SHA = "absent".
#
# Exit codes:
#   0 — success (at least one row parsed)
#   1 — no Review Gate section found or no data rows
parse_review_gate_table() {
  local file="$1"

  if ! grep -q '^## Review Gate[[:space:]]*$' "$file"; then
    printf 'review-gate-table.sh: missing ## Review Gate section in %s\n' "$file" >&2
    return 1
  fi

  awk '
    BEGIN { in_section = 0; in_table = 0; saw_sep = 0; rows = 0; errors = 0 }
    /^## Review Gate[[:space:]]*$/ { in_section = 1; in_table = 0; saw_sep = 0; next }
    in_section && /^## / { in_section = 0; in_table = 0; next }
    !in_section { next }

    { sub(/\r$/, "", $0) }

    in_section && !in_table {
      if ($0 ~ /^[[:space:]]*\|/) { in_table = 1; saw_sep = 0 }
      next
    }

    in_table {
      if ($0 !~ /^[[:space:]]*\|/) { in_table = 0; in_section = 0; next }
      if (!saw_sep && $0 ~ /^[[:space:]]*\|[[:space:]]*-+/) { saw_sep = 1; next }

      line = $0
      sub(/^[[:space:]]*\|/, "", line)
      sub(/\|[[:space:]]*$/, "", line)
      n = split(line, cells, /\|/)
      if (n < 3) {
        printf "review-gate-table.sh: malformed row: fewer than 3 columns\n" > "/dev/stderr"
        errors++
        next
      }
      if (n > 4) {
        printf "review-gate-table.sh: malformed row: more than 4 columns\n" > "/dev/stderr"
        errors++
        next
      }

      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cells[i])
      }

      sha = "absent"
      if (n >= 4 && cells[4] != "") { sha = cells[4] }

      printf "%s\t%s\t%s\t%s\n", cells[1], cells[2], cells[3], sha
      rows++
    }

    END { if (rows == 0 || errors > 0) exit 1 }
  ' "$file"
}
