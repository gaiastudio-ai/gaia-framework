#!/usr/bin/env bats
# never-run-subdir-guard.bats — fail CI if a bats subdirectory under
# plugins/gaia/tests/ is not wired into any runner.
#
# The full bats suite runs `bats <dir>` NON-recursively, so a SUBDIR of
# plugins/gaia/tests/ executes in CI only when something explicitly runs it:
# a dedicated plugin-ci.yml job, the selective-test stack matrix, or the
# component-subdir job this guard backs. A new subdir added without wiring
# would silently never run (the failure mode that hid a broken statusline
# suite and ~58 other never-run tests). This guard pins the known-wired set:
# any new subdir must be added here AND wired into a runner, or CI fails.

bats_require_minimum_version 1.5.0

setup() {
  TESTS_DIR="$(cd "$BATS_TEST_DIRNAME" && pwd)"
}

# Every subdir under plugins/gaia/tests/ that contains at least one .bats file
# MUST be in exactly one of these buckets.
#
#   COMPONENT_SUBDIRS  — run by the component-subdir CI job (plugin-ci.yml).
#   DEDICATED_JOB      — run by their own named CI job / the selective matrix.
#   FIXTURES_ONLY      — contain no .bats (data/fixtures); never expected to run.
#
# Keep these lists sorted. When you add a subdir of tests, add it here and wire
# it into a runner in the same change.
COMPONENT_SUBDIRS="adapters cluster-1 cluster-14 cluster-7 lib review-parity scripts skills spikes"
DEDICATED_OR_MATRIX="cluster-9 statusline"

@test "every bats subdir under plugins/gaia/tests/ is wired into a runner" {
  local unwired=()
  local d rel top
  # Find directories that directly contain at least one .bats file.
  while IFS= read -r d; do
    rel="${d#"$TESTS_DIR"/}"
    top="${rel%%/*}"            # first path segment under tests/
    case " $COMPONENT_SUBDIRS $DEDICATED_OR_MATRIX " in
      *" $top "*) continue ;;
    esac
    unwired+=("$top")
  done < <(find "$TESTS_DIR" -mindepth 2 -name '*.bats' -exec dirname {} \; | sort -u)

  if [ "${#unwired[@]}" -gt 0 ]; then
    printf 'UNWIRED test subdir(s) under plugins/gaia/tests/ — these would NEVER run in CI:\n' >&2
    printf '  %s\n' $(printf '%s\n' "${unwired[@]}" | sort -u) >&2
    printf 'Add each to COMPONENT_SUBDIRS or DEDICATED_OR_MATRIX in this guard AND wire it into a runner.\n' >&2
    return 1
  fi
}

@test "every subdir this guard claims as a component subdir still exists and has bats" {
  # Prevent the lists from rotting: a claimed subdir that no longer has bats
  # should be removed from the list (keeps the guard honest).
  local missing=()
  local s
  for s in $COMPONENT_SUBDIRS; do
    if ! find "$TESTS_DIR/$s" -name '*.bats' -print -quit 2>/dev/null | grep -q .; then
      missing+=("$s")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'These guard-listed component subdirs no longer contain bats (remove from the list):\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  fi
}
