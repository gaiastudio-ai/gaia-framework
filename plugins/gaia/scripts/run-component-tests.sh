#!/usr/bin/env bash
# run-component-tests.sh — run the bats assigned to a component in the
# component manifest, for a component selective-test stack's test_cmd.
#
# The manifest (component-manifest.tsv, produced by bats-component-tagger.sh)
# maps each top-level plugin bats to exactly one component, conservatively
# defaulting unresolved / cross-cutting tests to `core`. A component stack's
# test_cmd calls this with the component name; it runs that component's bats
# (hardware-dependent host-timing tests excluded, matching the rest of CI).
#
# The manifest is the SINGLE source of truth shared by the stack test_cmds and
# the drift-guard, so the set a stack runs can never silently diverge from the
# tagger's classification.
#
# Usage:
#   run-component-tests.sh <component> [--list|--count]
#     <component>  e.g. scripts-lib | scripts-brain | scripts-review-common |
#                  scripts-sprint | skills
#     --list       print the resolved bats paths (one per line) and exit.
#     --count      print the number of test cases bats would run over the
#                  resolved set (via `bats --count`) and exit. This drives the
#                  same `bats` execution path as a real run but without
#                  executing the tests, so a guard can cheaply assert the
#                  component's command yields a NON-EMPTY plan — catching the
#                  non-recursive-bats trap where a misconfigured set would run
#                  an empty `1..0` plan and silently test nothing.
#
# Exit codes: bats' exit code; 1 on usage / unknown component / empty set.

set -euo pipefail
LC_ALL=C
export LC_ALL

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${_SELF_DIR}/../tests"
MANIFEST="${TESTS_DIR}/component-manifest.tsv"

COMPONENT="${1:-}"
LIST_ONLY=0
COUNT_ONLY=0
case "${2:-}" in
  --list)  LIST_ONLY=1 ;;
  --count) COUNT_ONLY=1 ;;
esac

if [ -z "$COMPONENT" ] || [ "$COMPONENT" = "-h" ] || [ "$COMPONENT" = "--help" ]; then
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  [ -z "$COMPONENT" ] && exit 1 || exit 0
fi

[ -f "$MANIFEST" ] || { printf 'run-component-tests.sh: manifest not found: %s\n' "$MANIFEST" >&2; exit 1; }

# Resolve the component's bats basenames -> existing paths under tests/.
_resolve() {
  awk -F'\t' -v c="$COMPONENT" '$1==c {print $2}' "$MANIFEST" \
    | while IFS= read -r base; do
        [ -n "$base" ] || continue
        [ -f "$TESTS_DIR/$base" ] && printf '%s\n' "$TESTS_DIR/$base"
      done
}

files="$(_resolve)"
if [ -z "$files" ]; then
  printf 'run-component-tests.sh: no bats for component %s in manifest (or none on disk)\n' "$COMPONENT" >&2
  exit 1
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "$files"
  exit 0
fi

if [ "$COUNT_ONLY" -eq 1 ]; then
  # shellcheck disable=SC2086  # one path per arg; bats filenames never contain spaces
  exec bats --count --filter-tags '!hardware-dependent' $files
fi

# shellcheck disable=SC2086  # one path per arg; bats filenames never contain spaces
exec bats --filter-tags '!hardware-dependent' $files
