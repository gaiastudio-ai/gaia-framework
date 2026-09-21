#!/usr/bin/env bash
# run-component-tests.sh — run the bats assigned to a component in the
# component manifest, for a component selective-test stack's test_cmd.
#
# The manifest (component-manifest.tsv, produced by bats-component-tagger.sh)
# maps each plugin bats — at any depth under the test tree — to exactly one
# component, conservatively defaulting unresolved / cross-cutting tests to
# `core`. A component stack's test_cmd calls this with the component name; it
# runs that component's bats (hardware-dependent host-timing tests excluded,
# matching the rest of CI).
#
# Each manifest entry is a path RELATIVE to the test tree root, resolved here
# as `<tests-dir>/<entry>`. It is not a bare basename: several basenames occur
# at more than one depth, and an entry naming only a basename could not say
# which of them it meant.
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
# GAIA_COMPONENT_TESTS_DIR lets a test drive the resolver over a fixture tree.
TESTS_DIR="${GAIA_COMPONENT_TESTS_DIR:-${_SELF_DIR}/../tests}"
MANIFEST="${TESTS_DIR}/component-manifest.tsv"

COMPONENT="${1:-}"
LIST_ONLY=0
COUNT_ONLY=0
case "${2:-}" in
  --list)  LIST_ONLY=1 ;;
  --count) COUNT_ONLY=1 ;;
esac

if [ -z "$COMPONENT" ] || [ "$COMPONENT" = "-h" ] || [ "$COMPONENT" = "--help" ]; then
  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  [ -z "$COMPONENT" ] && exit 1 || exit 0
fi

[ -f "$MANIFEST" ] || { printf 'run-component-tests.sh: manifest not found: %s\n' "$MANIFEST" >&2; exit 1; }

# Resolve the component's manifest entries -> existing paths under the test
# tree. Each entry is tree-relative, so a nested file resolves at its own path
# and two files sharing a basename stay distinct.
#
# An entry that does not resolve is REPORTED and FATAL, never dropped. The
# earlier resolver tested `[ -f ]` and emitted nothing when the test failed, so
# a manifest row naming a file that was not there simply vanished: the stack
# ran a smaller set and still reported green. That is the failure mode this
# whole mechanism exists to prevent, and it is precisely what would have
# happened had the tagger's enumeration been widened while this resolver still
# expected bare basenames — every nested row would have silently routed
# nothing. Treating it as fatal makes a manifest/tree divergence stop the run
# instead of quietly shrinking it; the fix is always to regenerate the
# manifest, which the drift guard demands anyway.
UNRESOLVED_COUNT=0

# _resolve — print one absolute path per manifest entry for $COMPONENT.
_resolve() {
  local rel missing=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -f "$TESTS_DIR/$rel" ]; then
      printf '%s\n' "$TESTS_DIR/$rel"
    else
      printf 'run-component-tests.sh: manifest entry does not resolve on disk: %s (expected at %s)\n' \
        "$rel" "$TESTS_DIR/$rel" >&2
      missing=$((missing + 1))
    fi
  done < <(awk -F'\t' -v c="$COMPONENT" '$1==c {print $2}' "$MANIFEST")
  # Report the count through a file so the caller sees it despite the subshell
  # a command substitution puts this function in.
  printf '%s\n' "$missing" > "$UNRESOLVED_FILE"
}

UNRESOLVED_FILE="$(mktemp "${TMPDIR:-/tmp}/run-component-tests.XXXXXX")"
trap 'rm -f "$UNRESOLVED_FILE"' EXIT

files="$(_resolve)"
UNRESOLVED_COUNT="$(cat "$UNRESOLVED_FILE" 2>/dev/null || printf '0')"

if [ "${UNRESOLVED_COUNT:-0}" -gt 0 ]; then
  printf 'run-component-tests.sh: %s manifest entr%s for component %s could not be resolved; refusing to run a silently smaller set. Regenerate the manifest with bats-component-tagger.sh.\n' \
    "$UNRESOLVED_COUNT" \
    "$( [ "$UNRESOLVED_COUNT" -eq 1 ] && printf 'y' || printf 'ies' )" \
    "$COMPONENT" >&2
  exit 1
fi

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
