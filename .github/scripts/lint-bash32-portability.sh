#!/usr/bin/env bash
# lint-bash32-portability.sh — CI lint for Bash 4+ constructs in host-facing scripts
#
# Scans .sh files under one or more directories (recursively) for constructs
# that require Bash 4.0+ and fail on macOS system bash 3.2.57:
#
#   - declare -A / declare -gA  (associative arrays, Bash 4.0 / 4.2)
#   - declare -g                (global scope modifier, Bash 4.2)
#   - local -A / typeset -A     (associative arrays via local/typeset, Bash 4.0)
#   - local -n / local -g       (namerefs/global via local, Bash 4.3 / 4.2)
#   - declare -n                (namerefs, Bash 4.3)
#   - mapfile / readarray       (Bash 4.0)
#   - ${var,,} / ${var^^}       (case-modification expansion, Bash 4.0)
#   - ${arr[-N]}                (negative array indices, Bash 4.3)
#   - [[ -v var ]]              (variable-set test, Bash 4.2)
#   - &>>                       (append-redirect stdout+stderr, Bash 4.0)
#   - |&                        (pipe stderr, Bash 4.0)
#   - coproc                    (coprocess, Bash 4.0)
#   - $BASHPID                  (subshell PID variable, Bash 4.0)
#   - read -i / read -N         (readline default / exact-count read, Bash 4.0)
#   - {var}>file                (named fd redirection, Bash 4.1)
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
# Baseline: use --baseline <file> to supply a TSV of (path, max-count)
# ceilings. A baselined file is allowed up to max-count violations; exceeding
# the ceiling fails the lint. Files not in the baseline must have zero
# violations. The baseline count may never increase.
#
# Usage:
#   lint-bash32-portability.sh [--baseline <file>] <scripts-dir> [<scripts-dir2> ...]
#
# Exit codes:
#   0 — no violations found (or all within baseline ceilings)
#   1 — one or more violations exceed their ceiling (details on stdout)
#   2 — usage error

set -euo pipefail
LC_ALL=C; export LC_ALL

BASELINE_FILE=""

# Parse --baseline flag.
if [ "${1:-}" = "--baseline" ]; then
  if [ $# -lt 2 ] || [ ! -f "$2" ]; then
    printf 'Error: --baseline requires a readable file path\n' >&2
    exit 2
  fi
  BASELINE_FILE="$2"
  shift 2
fi

if [ $# -lt 1 ]; then
  printf 'Usage: lint-bash32-portability.sh [--baseline <file>] <scripts-dir> [<scripts-dir2> ...]\n' >&2
  exit 2
fi

# Validate all directories exist before scanning.
for d in "$@"; do
  if [ ! -d "$d" ]; then
    printf 'Error: not a directory: %s\n' "$d" >&2
    exit 2
  fi
done

# Load baseline ceilings into a temp file for lookup (bash 3.2 compatible).
baseline_tmp=""
if [ -n "$BASELINE_FILE" ]; then
  baseline_tmp="$(mktemp -t baseline.XXXXXX)"
  # Strip comments and blank lines, output "path\tmax".
  grep -v '^[[:space:]]*#' "$BASELINE_FILE" | grep -v '^[[:space:]]*$' > "$baseline_tmp" 2>/dev/null || true
fi

# Look up a file's baseline ceiling. Returns the ceiling on stdout, or empty
# if the file is not baselined (meaning ceiling is 0).
baseline_ceiling() {
  local file_path="$1"
  if [ -z "$baseline_tmp" ]; then
    return 0
  fi
  # Match the path exactly in the first column.
  awk -F'\t' -v p="$file_path" '$1 == p { print $2; exit }' "$baseline_tmp"
}

violations=0
# Track per-file violation counts for baseline enforcement.
# Use a temp file: "path\tcount" (bash 3.2 compatible, no associative arrays).
file_counts_tmp="$(mktemp -t filecounts.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f '$baseline_tmp' '$file_counts_tmp'" EXIT

scan_dir() {
  local scan_dir="$1"

  # Collect all .sh files under the scan directory.
  while IFS= read -r script; do
    [ -z "$script" ] && continue

    # Check for opt-out directive.
    if grep -q '# bash32-portability-lint: skip' "$script" 2>/dev/null; then
      continue
    fi

    # Two-pass scan: awk strips comments and numbers lines, then grep
    # checks each non-comment line for Bash 4+ constructs.  The awk output
    # format is "NR:content", so patterns must not assume ^ is start-of-line
    # content — the line number and colon precede the code.

    hits="$(awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      { printf "%d:%s\n", NR, $0 }
    ' "$script" | grep -E \
        'declare[[:space:]]+-[a-zA-Z]*A|declare[[:space:]]+-[a-zA-Z]*g[[:space:]]|declare[[:space:]]+-gA|(local|typeset)[[:space:]]+-[a-zA-Z]*A|(local)[[:space:]]+-[a-zA-Z]*n[[:space:]]|(local)[[:space:]]+-[a-zA-Z]*g[[:space:]]|declare[[:space:]]+-[a-zA-Z]*n[[:space:]]|(^|[^a-zA-Z0-9_])mapfile([[:space:]]|$)|(^|[^a-zA-Z0-9_])readarray([[:space:]]|$)|\$\{[^}]*(,,|\^\^)|\$\{[^}]*\[-[0-9]|\[\[[[:space:]]+-v[[:space:]]|&>>[^&]|[[:space:]]\|&|(^|[^a-zA-Z0-9_])coproc([[:space:]]|$)|\$BASHPID|\$\{BASHPID|read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[iN]|[^$]\{[a-zA-Z_][a-zA-Z0-9_]*\}[><]' \
      2>/dev/null || true)"

    if [ -n "$hits" ]; then
      local file_hit_count=0
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        lineno="${hit%%:*}"
        content="${hit#*:}"
        printf '%s:%s: %s\n' "$script" "$lineno" "$content"
        file_hit_count=$((file_hit_count + 1))
      done <<EOF
$hits
EOF
      printf '%s\t%d\n' "$script" "$file_hit_count" >> "$file_counts_tmp"
    fi

  done < <(find "$scan_dir" -name '*.sh' -type f 2>/dev/null | sort)
}

# Scan each directory argument.
for d in "$@"; do
  scan_dir "$d"
done

# Enforce baseline ceilings.
exceeded=0
while IFS=$'\t' read -r filepath count; do
  [ -z "$filepath" ] && continue
  ceiling="$(baseline_ceiling "$filepath")"
  if [ -z "$ceiling" ]; then
    ceiling=0
  fi
  if [ "$count" -gt "$ceiling" ]; then
    if [ "$ceiling" -eq 0 ]; then
      printf 'FAIL: %s has %d violation(s) (no baseline; expected 0)\n' "$filepath" "$count" >&2
    else
      printf 'FAIL: %s has %d violation(s), exceeds baseline ceiling of %d\n' "$filepath" "$count" "$ceiling" >&2
    fi
    exceeded=$((exceeded + count))
  else
    printf 'BASELINE: %s has %d violation(s) (ceiling %d — OK)\n' "$filepath" "$count" "$ceiling" >&2
  fi
done < "$file_counts_tmp"

if [ "$exceeded" -gt 0 ]; then
  printf '\nbash32-portability-lint: %d violation(s) exceed baseline ceilings.\n' "$exceeded" >&2
  printf 'Bash 4+ constructs are not allowed in host-facing scripts that\n' >&2
  printf 'must run on macOS system bash 3.2. Detected constructs include:\n' >&2
  printf '  declare -A/-g/-n, local -A/-n/-g, typeset -A, mapfile, readarray,\n' >&2
  # shellcheck disable=SC2016
  printf '  ${var,,}, ${var^^}, ${arr[-N]}, [[ -v, &>>, |&, coproc,\n' >&2
  # shellcheck disable=SC2016
  printf '  $BASHPID, read -i/-N, {fd}> named-fd redirection.\n' >&2
  printf 'To opt out, add: # bash32-portability-lint: skip (reason)\n' >&2
  exit 1
fi

exit 0
