#!/usr/bin/env bats
# brain-health.bats — coverage for the brain-health unlinked-node view
# (scripts/brain/brain-health.sh).
#
# Behaviour under test:
#   - brain-health re-derives the C2 "unlinked" verdict for every manifest entry
#     by sourcing the harvester's four-source linked predicate, and lists every
#     unlinked node. No schema field is read for this — the verdict is recomputed.
#   - It NEVER drops or errors on an unlinked node: exit 0 even when unlinked
#     nodes are present (a traceability gap is a quality signal, not a failure).
#   - The output is deterministic (sorted).
#   - A missing source file for an entry is handled without error.
#   - A missing manifest yields exit 0 with an explanatory line.
#
# Each test builds an isolated per-test project tree (mirroring brain-reindex.bats)
# and points the path helper at it via CLAUDE_PROJECT_ROOT, so brain-health runs
# on a fixture project and never touches the real .gaia/ tree.

load 'test_helper.bash'

setup() {
  common_setup
  REINDEX="$SCRIPTS_DIR/brain/gaia-brain-reindex.sh"
  HEALTH="$SCRIPTS_DIR/brain/brain-health.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brain-reindex"

  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia"
  cp -R "$FIX/artifacts" "$PROJ/.gaia/artifacts"
  cp -R "$FIX/state"     "$PROJ/.gaia/state"
  cp -R "$FIX/memory"    "$PROJ/.gaia/memory"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  KNOW="$PROJ/.gaia/knowledge"
  MANIFEST="$KNOW/brain-index.yaml"

  # Build the manifest the health view consumes.
  run bash "$REINDEX"
  [ "$status" -eq 0 ]
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

_run_health() {
  run bash "$HEALTH" "$@"
}

@test "brain-health lists the C2-unlinked orphan node" {
  _run_health
  [ "$status" -eq 0 ]
  # The orphan story (no traces_to / no epic / no Allocates / no matrix row) is
  # listed as unlinked.
  printf '%s\n' "$output" | grep -q 'E777-S6'
}

@test "brain-health does NOT list a fully-linked node as unlinked" {
  _run_health
  [ "$status" -eq 0 ]
  # The primary story is linked (frontmatter traces_to + epics + matrix). It must
  # NOT appear in the unlinked list. Assert against the unlinked section only:
  # the linked primary key must not be flagged.
  # Render to a file and inspect the listed (unlinked) keys.
  printf '%s\n' "$output" > "$TEST_TMP/health.out"
  # The non-story artifacts (adr-fragment, epics-and-stories, matrix, sprint-status)
  # are unlinked too (they carry no governance edges), so they may appear. The
  # contract under test: a LINKED story key is never flagged.
  ! grep -qE '^[^A-Za-z0-9]*E777-S2([^0-9]|$)' "$TEST_TMP/health.out"
}

@test "brain-health exits 0 even when unlinked nodes are present" {
  # AC3 core: a traceability gap is surfaced, never raised as a failure.
  _run_health
  [ "$status" -eq 0 ]
  # And it did surface at least one unlinked node (the orphan).
  printf '%s\n' "$output" | grep -q 'E777-S6'
}

@test "brain-health output is deterministic across runs" {
  _run_health
  [ "$status" -eq 0 ]
  local first="$output"
  _run_health
  [ "$status" -eq 0 ]
  [ "$first" = "$output" ]
}

@test "brain-health reports a count of unlinked nodes" {
  _run_health
  [ "$status" -eq 0 ]
  # A count line is emitted (the human payoff: how many gaps).
  printf '%s\n' "$output" | grep -qiE 'unlinked|gap'
}

@test "brain-health handles a manifest entry whose source file is missing" {
  # Remove the orphan's source file AFTER the manifest was built — the entry now
  # points at a missing file. brain-health must not error.
  rm -f "$PROJ/.gaia/artifacts/implementation-artifacts/E777-S6-orphan.md"
  _run_health
  [ "$status" -eq 0 ]
}

@test "brain-health on a missing manifest exits 0 with an explanatory line" {
  rm -f "$MANIFEST"
  _run_health
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'no.*manifest|not found|no brain index'
}

@test "brain-health accepts an explicit --manifest path" {
  _run_health --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'E777-S6'
}
