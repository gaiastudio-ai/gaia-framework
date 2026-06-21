#!/usr/bin/env bats
# component-manifest-drift-guard.bats — keep the committed component manifest in
# lockstep with the tagger that generates it, and with the component test runner
# that consumes it.
#
# The manifest (component-manifest.tsv) maps each top-level plugin bats to one
# component (conservatively defaulting unresolved / cross-cutting tests to the
# catch-all `core`). It is the SINGLE source of truth shared by:
#   - run-component-tests.sh (a component stack's test_cmd reads it), and
#   - the component selective-test stacks.
# If the committed manifest drifts from a fresh tagger run (e.g. a new bats was
# added, or a test changed which component it exercises), a component stack
# would run a stale set — silently skipping a test that should run (a
# false-green) or running a stale list. This guard fails CI on any drift so the
# manifest is regenerated in the same change.

bats_require_minimum_version 1.5.0

setup() {
  REPO_TESTS="$(cd "$BATS_TEST_DIRNAME" && pwd)"
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  TAGGER="$SCRIPTS/bats-component-tagger.sh"
  RUNNER="$SCRIPTS/run-component-tests.sh"
  MANIFEST="$REPO_TESTS/component-manifest.tsv"
}

@test "the tagger and runner exist and are executable" {
  [ -x "$TAGGER" ] || [ -f "$TAGGER" ]
  [ -x "$RUNNER" ] || [ -f "$RUNNER" ]
}

@test "the committed component manifest exists" {
  [ -f "$MANIFEST" ]
}

@test "the committed manifest matches a fresh tagger run (no drift)" {
  local fresh="$BATS_TEST_TMPDIR/fresh-manifest.tsv"
  run bash "$TAGGER" --tests-dir "$REPO_TESTS" --format tsv
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$fresh"
  if ! diff -u "$MANIFEST" "$fresh"; then
    echo "--- The committed component-manifest.tsv is STALE." >&2
    echo "--- Regenerate it: bats-component-tagger.sh --manifest plugins/gaia/tests/component-manifest.tsv" >&2
    return 1
  fi
}

@test "the tagger is deterministic (two runs are byte-identical)" {
  local a="$BATS_TEST_TMPDIR/a.tsv" b="$BATS_TEST_TMPDIR/b.tsv"
  bash "$TAGGER" --tests-dir "$REPO_TESTS" --format tsv > "$a"
  bash "$TAGGER" --tests-dir "$REPO_TESTS" --format tsv > "$b"
  diff "$a" "$b"
}

@test "every non-core component in the manifest resolves a non-empty runnable set" {
  # For each component the manifest assigns (other than core), the runner must
  # resolve at least one on-disk bats — otherwise a stack pointing at it would
  # run nothing (a silent gap).
  local comps
  comps="$(cut -f1 "$MANIFEST" | sort -u | grep -v '^core$' || true)"
  [ -n "$comps" ]
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    run bash "$RUNNER" "$c" --list
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done <<< "$comps"
}

@test "unresolved and cross-cutting tests are conservatively assigned to core" {
  # The catch-all must be non-empty (the suite has many cross-cutting tests);
  # an empty core would mean the tagger over-narrowed, risking false-greens.
  run bash -c "cut -f1 '$MANIFEST' | grep -c '^core$'"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}
