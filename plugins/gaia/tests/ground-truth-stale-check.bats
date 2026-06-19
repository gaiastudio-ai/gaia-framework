#!/usr/bin/env bats
# ground-truth-stale-check.bats — TC-GTS-1..6 + TC-GTS-15
#
# Tests the shared ground-truth staleness predicate:
#   scripts/lib/ground-truth-stale-check.sh :: check_ground_truth_staleness
#
# Contract under test:
#   - Compared roots = planning-artifacts + implementation-artifacts ONLY.
#   - STALE when any tracked source under a compared root is newer than the
#     validator-sidecar ground-truth.md.
#   - FRESH when ground-truth.md is the newest path → writes NO marker.
#   - UNCERTAIN (absent gt.md / equal mtime / unresolvable) → STALE (fail-safe).
#   - On STALE: write the `.ground-truth-stale` marker at the TOP LEVEL of the
#     memory dir; never touch compared-input mtimes; idempotent.
#
# Determinism: per-test tmpdir, CLAUDE_PROJECT_ROOT + MEMORY_PATH + root
# overrides all point into the tmpdir; mtimes are driven by `touch -t`.

load 'test_helper.bash'

setup() {
  common_setup
  LIB="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)/ground-truth-stale-check.sh"
  export LIB

  # Isolated project tree under the per-test tmpdir.
  PROJ="$TEST_TMP/proj"
  PLANNING="$PROJ/.gaia/artifacts/planning-artifacts"
  IMPL="$PROJ/.gaia/artifacts/implementation-artifacts"
  MEM="$PROJ/.gaia/memory"
  SIDECAR="$MEM/validator-sidecar"
  GT="$SIDECAR/ground-truth.md"
  MARKER="$MEM/.ground-truth-stale"
  mkdir -p "$PLANNING" "$IMPL" "$SIDECAR"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  export MEMORY_PATH="$MEM"
  export GAIA_GT_PLANNING_ROOT="$PLANNING"
  export GAIA_GT_IMPL_ROOT="$IMPL"
  export PLANNING IMPL MEM SIDECAR GT MARKER PROJ
}

teardown() { common_teardown; }

# Helper: stamp a file at an explicit mtime (UTC, deterministic).
stamp() { touch -t "$2" "$1"; }

# Helper: portable epoch-seconds mtime. GNU coreutils `stat -f` means
# `--file-system` and succeeds with the wrong value, so probe GNU (`-c %Y`)
# FIRST and only fall back to BSD (`-f %m`); validate all-digits.
mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" ;; esac
  printf '%s' "$m"
}

# TC-GTS-1 (AC1): a tracked source newer than ground-truth.md → STALE.
@test "planning source newer than ground-truth → STALE" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601020000   # newer than gt

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

@test "implementation-tree source newer than ground-truth → STALE" {
  printf 'gt\n' > "$GT"
  printf 'story\n' > "$IMPL/story.md"
  stamp "$GT" 202601010000
  stamp "$IMPL/story.md" 202601020000

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-2 (AC2): ground-truth.md newest → FRESH, and NO marker written.
@test "ground-truth newest → FRESH and no marker written" {
  printf 'prd\n' > "$PLANNING/prd.md"
  printf 'story\n' > "$IMPL/story.md"
  printf 'gt\n' > "$GT"
  stamp "$PLANNING/prd.md" 202601010000
  stamp "$IMPL/story.md" 202601010000
  stamp "$GT" 202601020000   # newest

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
  [ ! -e "$MARKER" ]
}

# TC-GTS-2 also asserts test-artifacts / state are NOT compared roots (AC1).
@test "newer test-artifacts/state files do NOT make it stale (out of compared roots)" {
  mkdir -p "$PROJ/.gaia/artifacts/test-artifacts" "$PROJ/.gaia/state"
  printf 'gt\n' > "$GT"
  printf 'tp\n' > "$PROJ/.gaia/artifacts/test-artifacts/test-plan.md"
  printf 'ss\n' > "$PROJ/.gaia/state/sprint-status.yaml"
  stamp "$GT" 202601010000
  stamp "$PROJ/.gaia/artifacts/test-artifacts/test-plan.md" 202601090000
  stamp "$PROJ/.gaia/state/sprint-status.yaml" 202601090000

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
  [ ! -e "$MARKER" ]
}

# TC-GTS-3 (AC3): UNCERTAIN → STALE. Absent gt.md.
@test "absent ground-truth.md → STALE (fail-safe)" {
  printf 'prd\n' > "$PLANNING/prd.md"
  # No $GT file at all.
  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-3 (AC3): equal mtime → STALE (find -newer is strict; tie is ambiguous → fail-safe).
@test "equal mtime source vs ground-truth → STALE (fail-safe)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  touch -r "$GT" "$PLANNING/prd.md"   # exactly equal mtime

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-3 (AC3): unresolvable / missing memory dir → STALE.
@test "unresolvable ground-truth (missing sidecar dir) → STALE" {
  rm -rf "$SIDECAR"
  printf 'prd\n' > "$PLANNING/prd.md"
  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-4 (AC3): CI checkout mtime-reset — all files get the SAME fresh mtime.
# find -newer is strict so equal mtimes are not "newer"; tie → UNCERTAIN → STALE.
# This guards against a false-negative (false-FRESH) on a CI checkout.
@test "CI checkout resets all mtimes equal → UNCERTAIN → STALE (no false-negative)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  printf 'story\n' > "$IMPL/story.md"
  # Simulate a git checkout: every tracked file stamped identically.
  touch -t 202602020202 "$GT" "$PLANNING/prd.md" "$IMPL/story.md"

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-5 (AC5/AC6): sourceable smoke — file sources cleanly and exposes the fn.
@test "helper is sourceable and exposes check_ground_truth_staleness" {
  run bash -c '. "$LIB"; type -t check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

@test "sourcing the helper has no side effects (writes no marker on load)" {
  printf 'gt\n' > "$GT"
  stamp "$GT" 202601010000
  run bash -c '. "$LIB"; true'
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

# TC-GTS-6 (AC4): idempotent + read-only w.r.t. compared inputs.
@test "STALE run is idempotent and never mutates input mtimes" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  printf 'story\n' > "$IMPL/story.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601050000   # newer → STALE
  stamp "$IMPL/story.md" 202601030000

  # Capture input mtimes before.
  before_prd="$(mtime "$PLANNING/prd.md")"
  before_story="$(mtime "$IMPL/story.md")"
  before_gt="$(mtime "$GT")"

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]

  # Second run — still STALE, marker still present (idempotent).
  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]

  # Input mtimes unchanged.
  after_prd="$(mtime "$PLANNING/prd.md")"
  after_story="$(mtime "$IMPL/story.md")"
  after_gt="$(mtime "$GT")"
  [ "$before_prd" = "$after_prd" ]
  [ "$before_story" = "$after_story" ]
  [ "$before_gt" = "$after_gt" ]
}

# TC-GTS-15 (AC4): STALE verdict writes the marker at the marker path,
# discoverable by a maxdepth-1 `_memory/.*-stale` scan.
@test "STALE writes .ground-truth-stale marker at memory-dir top level" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601020000

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]

  # Discoverable by the registry scanner's maxdepth-1 contract.
  run bash -c 'find "$MEM" -maxdepth 1 -type f -name ".*-stale"'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF '.ground-truth-stale'
}
