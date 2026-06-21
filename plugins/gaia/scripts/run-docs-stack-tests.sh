#!/usr/bin/env bash
# run-docs-stack-tests.sh — run the documentation-site bats for the gaia-docs
# selective-test component stack.
#
# The set of bats that exercise the documentation site cannot be pinned as a
# reliable static list: some reference a `documentation/` path literal, others
# assign the doc directory to a shell variable (`DOC_SITE="$ROOT/documentation"`)
# and never write the literal `documentation/` token. A hand-maintained list
# drifts silently (a new docs page test added without wiring it in would NOT run
# on a docs-only PR — a false-green). So this script DERIVES the set at run time
# from one canonical signal, and the component-test-partition guard asserts the
# gaia-docs test_cmd routes through this script (not a static list) so the two
# can never disagree.
#
# Canonical signal — a bats file is a documentation-site test iff it either:
#   1. references a `documentation/<path>` literal, OR
#   2. assigns a path ending in `/documentation` to a variable
#      (the `DOC_SITE` / `DOC_DIR` convention).
#
# Safety net: the gaia-core stack owns the whole test tree and runs the full
# suite on any core change and on the staging->main promotion, so anything this
# heuristic might miss is still caught there — this script only has to be a
# correct OPTIMISATION for docs-only PRs, never the sole gate.
#
# Usage: run-docs-stack-tests.sh [--list]
#   --list   print the resolved bats files, one per line, and exit (no run).
#
# Exit codes: bats' exit code (0 = all green), or 1 on usage / no-files error.

set -euo pipefail
LC_ALL=C
export LC_ALL

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${DOCS_TESTS_DIR_OVERRIDE:-${_SELF_DIR}/../tests}"

# The canonical pattern (kept in ONE place; the guard reads it from here).
DOCS_BATS_PATTERN='documentation/|/documentation"'

_resolve_docs_bats() {
  # Files matching the canonical signal, excluding the partition guard itself
  # (it names the pattern in its own assertions, it is not a docs-site test).
  grep -lE "$DOCS_BATS_PATTERN" "$TESTS_DIR"/*.bats 2>/dev/null \
    | grep -v '/component-test-partition\.bats$' \
    | sort -u
}

_main() {
  local list_only=0
  case "${1:-}" in
    --list) list_only=1 ;;
    "" ) ;;
    * ) printf 'run-docs-stack-tests.sh: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac

  local files
  files="$(_resolve_docs_bats)"
  if [[ -z "$files" ]]; then
    printf 'run-docs-stack-tests.sh: no documentation-site bats resolved under %s\n' "$TESTS_DIR" >&2
    exit 1
  fi

  if [[ "$list_only" -eq 1 ]]; then
    printf '%s\n' "$files"
    return 0
  fi

  # shellcheck disable=SC2086  # word-splitting is intentional: one path per arg
  exec bats $files
}

_main "$@"
