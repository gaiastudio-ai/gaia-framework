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
# Usage:
#   lint-bash32-portability.sh <scripts-dir> [<scripts-dir2> ...]
#
# Exit codes:
#   0 — no violations found
#   1 — one or more violations found (details on stdout)
#   2 — usage error

set -euo pipefail
LC_ALL=C; export LC_ALL

if [ $# -lt 1 ]; then
  printf 'Usage: lint-bash32-portability.sh <scripts-dir> [<scripts-dir2> ...]\n' >&2
  exit 2
fi

# Validate all directories exist before scanning.
for d in "$@"; do
  if [ ! -d "$d" ]; then
    printf 'Error: not a directory: %s\n' "$d" >&2
    exit 2
  fi
done

violations=0

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
    #
    # Pattern groups (each separated by | in the grep alternation):
    #
    # Group 1 — declare with -A flag (associative arrays):
    #   declare[[:space:]]+-[a-zA-Z]*A
    #
    # Group 2 — declare with -g flag (global scope):
    #   declare[[:space:]]+-[a-zA-Z]*g[[:space:]]
    #   declare[[:space:]]+-gA
    #
    # Group 3 — local/typeset with -A flag (associative arrays):
    #   (local|typeset)[[:space:]]+-[a-zA-Z]*A
    #
    # Group 4 — local with -n flag (namerefs):
    #   local[[:space:]]+-[a-zA-Z]*n[[:space:]]
    #
    # Group 5 — local with -g flag (global scope):
    #   local[[:space:]]+-[a-zA-Z]*g[[:space:]]
    #
    # Group 6 — declare with -n flag (namerefs):
    #   declare[[:space:]]+-[a-zA-Z]*n[[:space:]]
    #
    # Group 7 — mapfile/readarray commands:
    #   (^|[^a-zA-Z0-9_])(mapfile|readarray)([[:space:]]|$)
    #
    # Group 8 — case-modification expansion:
    #   \$\{[^}]*(,,|\^\^)
    #
    # Group 9 — negative array index:
    #   \$\{[^}]*\[-[0-9]
    #
    # Group 10 — [[ -v (variable-set test):
    #   \[\[[[:space:]]+-v[[:space:]]
    #
    # Group 11 — &>> (append-redirect stdout+stderr):
    #   &>>
    #
    # Group 12 — |& (pipe stderr shorthand):
    #   Requires preceding whitespace to avoid false positives inside
    #   string/regex character classes like [;|&=...].
    #   [[:space:]]\|&
    #
    # Group 13 — coproc command:
    #   (^|[^a-zA-Z0-9_])coproc([[:space:]]|$)
    #
    # Group 14 — $BASHPID variable:
    #   \$BASHPID|\$\{BASHPID
    #
    # Group 15 — read -i / read -N:
    #   Handles both single-group (read -i) and multi-group (read -e -i)
    #   forms by allowing zero or more -flag groups before the one
    #   containing i or N.
    #   read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[iN]
    #
    # Group 16 — {var}> named-fd redirection:
    #   Requires that { is NOT preceded by $ (which would make it a
    #   variable expansion like ${fd}>, not a named-fd redirect).
    #   [^$]\{[a-zA-Z_][a-zA-Z0-9_]*\}[><]

    hits="$(awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      { printf "%d:%s\n", NR, $0 }
    ' "$script" | grep -E \
        'declare[[:space:]]+-[a-zA-Z]*A|declare[[:space:]]+-[a-zA-Z]*g[[:space:]]|declare[[:space:]]+-gA|(local|typeset)[[:space:]]+-[a-zA-Z]*A|(local)[[:space:]]+-[a-zA-Z]*n[[:space:]]|(local)[[:space:]]+-[a-zA-Z]*g[[:space:]]|declare[[:space:]]+-[a-zA-Z]*n[[:space:]]|(^|[^a-zA-Z0-9_])mapfile([[:space:]]|$)|(^|[^a-zA-Z0-9_])readarray([[:space:]]|$)|\$\{[^}]*(,,|\^\^)|\$\{[^}]*\[-[0-9]|\[\[[[:space:]]+-v[[:space:]]|&>>[^&]|[[:space:]]\|&|(^|[^a-zA-Z0-9_])coproc([[:space:]]|$)|\$BASHPID|\$\{BASHPID|read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[iN]|[^$]\{[a-zA-Z_][a-zA-Z0-9_]*\}[><]' \
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

  done < <(find "$scan_dir" -name '*.sh' -type f 2>/dev/null | sort)
}

# Scan each directory argument.
for d in "$@"; do
  scan_dir "$d"
done

if [ "$violations" -gt 0 ]; then
  printf '\nbash32-portability-lint: %d violation(s) found.\n' "$violations" >&2
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
