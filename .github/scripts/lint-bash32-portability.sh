#!/usr/bin/env bash
# lint-bash32-portability.sh — CI lint for Bash 4+ constructs in host-facing scripts
#
# Scans .sh files under the given directory (recursively) for constructs that
# require Bash 4.0+ and fail on macOS system bash 3.2.57:
#
#   - declare -A / declare -gA  (associative arrays, Bash 4.0 / 4.2)
#   - declare -g                (global scope modifier, Bash 4.2)
#   - mapfile / readarray       (Bash 4.0)
#   - ${var,,} / ${var^^}       (case-modification expansion, Bash 4.0)
#   - ${arr[-N]}                (negative array indices, Bash 4.3)
#   - declare -n                (namerefs, Bash 4.3)
#
# Lines that are pure comments (leading # after optional whitespace) are
# excluded — comments documenting the avoidance of a construct are not
# violations.
#
# Opt-out: a script may carry a skip directive on any line:
#   # bash32-portability-lint: skip (reason)
# This excludes the entire file from the scan. Use only for scripts that
# carry an explicit Bash-version preflight guard.
#
# Usage:
#   lint-bash32-portability.sh <scripts-dir>
#
# Exit codes:
#   0 — no violations found
#   1 — one or more violations found (details on stdout)
#   2 — usage error

set -euo pipefail
LC_ALL=C; export LC_ALL

if [ $# -lt 1 ] || [ ! -d "$1" ]; then
  printf 'Usage: lint-bash32-portability.sh <scripts-dir>\n' >&2
  exit 2
fi

SCAN_DIR="$1"
violations=0

# Collect all .sh files under the scan directory.
while IFS= read -r script; do
  [ -z "$script" ] && continue

  # Check for opt-out directive.
  if grep -q '# bash32-portability-lint: skip' "$script" 2>/dev/null; then
    continue
  fi

  # Strip comment lines (lines whose first non-whitespace character is #),
  # then scan for Bash 4+ construct patterns.
  # We use awk to produce "<lineno>:<content>" for non-comment lines, then
  # grep for the patterns.
  #
  # Patterns (one per grep -E alternation):
  #   declare\s+-[a-zA-Z]*[gA]  — catches declare -gA, declare -A, declare -Ag, declare -g
  #   ^[[:space:]]*(mapfile|readarray)\b  — mapfile/readarray as a command
  #   \$\{[^}]*(,,|^^)          — case-modification expansion
  #   \$\{[^}]*\[-[0-9]         — negative array index
  #   declare\s+-[a-zA-Z]*n     — nameref (declare -n)

  # Two-pass scan: awk strips comments and numbers lines, then grep
  # checks each non-comment line for Bash 4+ constructs.  The awk output
  # format is "NR:content", so patterns must not assume ^ is start-of-line
  # content — the line number and colon precede the code.

  hits="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { printf "%d:%s\n", NR, $0 }
  ' "$script" | grep -E \
      'declare[[:space:]]+-[a-zA-Z]*A|declare[[:space:]]+-[a-zA-Z]*g[[:space:]]|declare[[:space:]]+-gA|(^|[^a-zA-Z0-9_])mapfile([[:space:]]|$)|(^|[^a-zA-Z0-9_])readarray([[:space:]]|$)|\$\{[^}]*(,,|\^\^)|\$\{[^}]*\[-[0-9]|declare[[:space:]]+-[a-zA-Z]*n[[:space:]]' \
    2>/dev/null || true)"

  if [ -n "$hits" ]; then
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      lineno="${hit%%:*}"
      content="${hit#*:}"
      printf '%s:%s: %s\n' "$script" "$lineno" "$content"
      violations=$((violations + 1))
    done <<EOF
$hits
EOF
  fi

done < <(find "$SCAN_DIR" -name '*.sh' -type f 2>/dev/null | sort)

if [ "$violations" -gt 0 ]; then
  printf '\nbash32-portability-lint: %d violation(s) found.\n' "$violations" >&2
  printf 'Bash 4+ constructs (declare -A, declare -g, mapfile, readarray,\n' >&2
  # shellcheck disable=SC2016
  printf '${var,,}, ${var^^}, ${arr[-N]}, declare -n) are not allowed in\n' >&2
  printf 'host-facing scripts that must run on macOS system bash 3.2.\n' >&2
  printf 'To opt out, add: # bash32-portability-lint: skip (reason)\n' >&2
  exit 1
fi

exit 0
