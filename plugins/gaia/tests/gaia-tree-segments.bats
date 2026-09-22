#!/usr/bin/env bats
# gaia-tree-segments.bats — unit tests for the shared tree-segment library.
#
# The library recovers the runtime tree's own path segments (the artifacts
# segment and the memory segment) WITHOUT attaching a root, so a script that
# composes its output from a caller-supplied root keeps its own root
# resolution. These tests pin the properties every consumer depends on:
#
#   1. Two non-empty segments are emitted, artifacts first then memory.
#   2. Both are RELATIVE — no leading slash. The sentinel strip is the whole
#      point of the library; a leaked sentinel would turn every consumer's
#      relative output absolute against a tree the caller never named.
#   3. The probe root does not escape into the caller's environment.
#   4. A caller's own PROJECT_ROOT is untouched by the call.

load 'test_helper.bash'

setup() {
  common_setup
  LIB="$SCRIPTS_DIR/lib/gaia-tree-segments.sh"
  mkdir -p "$TEST_TMP/proj"
  FIXTURE_ROOT="$( cd "$TEST_TMP/proj" && pwd -P )"
  cd "$FIXTURE_ROOT"
}

teardown() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH \
        _GAIA_PATHS_LOADED \
        GAIA_ARTIFACTS_DIR GAIA_MEMORY_DIR 2>/dev/null || true
  common_teardown
}

@test "the tree-segment library exists at its canonical path" {
  [ -f "$LIB" ]
}

@test "sourcing the tree-segment library defines the segment function" {
  run bash -c ". '$LIB' && type -t gaia_tree_segments"
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

@test "the segment function emits two non-empty segments" {
  run bash -c ". '$LIB' && gaia_tree_segments"
  [ "$status" -eq 0 ]

  local artifacts memory
  artifacts="$(printf '%s\n' "$output" | sed -n '1p')"
  memory="$(printf '%s\n' "$output" | sed -n '2p')"

  [ -n "$artifacts" ]
  [ -n "$memory" ]
  [ "$(printf '%s\n' "$output" | grep -c '.')" -eq 2 ]
}

@test "both emitted segments are relative — no leading slash" {
  run bash -c ". '$LIB' && gaia_tree_segments"
  [ "$status" -eq 0 ]

  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      /*) printf 'segment is absolute, sentinel leaked: %s\n' "$line" >&2
          return 1 ;;
    esac
  done <<< "$output"
}

@test "neither segment carries the probe sentinel" {
  run bash -c ". '$LIB' && gaia_tree_segments"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q 'gaia-path-segment-probe'
}

@test "the artifacts segment is emitted first, the memory segment second" {
  run bash -c ". '$LIB' && gaia_tree_segments"
  [ "$status" -eq 0 ]

  local artifacts memory
  artifacts="$(printf '%s\n' "$output" | sed -n '1p')"
  memory="$(printf '%s\n' "$output" | sed -n '2p')"

  # Compared against the paths helper's own answer under the same sentinel,
  # so this pins the ORDER without spelling either tree name here.
  local expect_artifacts expect_memory
  expect_artifacts="$(
    PROJECT_ROOT="/gaia-path-segment-probe" _GAIA_PATHS_LOADED="" \
      bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${GAIA_ARTIFACTS_DIR#"$_GAIA_ROOT_CANON"/}"' \
      _ "$SCRIPTS_DIR/lib/gaia-paths.sh"
  )"
  expect_memory="$(
    PROJECT_ROOT="/gaia-path-segment-probe" _GAIA_PATHS_LOADED="" \
      bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${GAIA_MEMORY_DIR#"$_GAIA_ROOT_CANON"/}"' \
      _ "$SCRIPTS_DIR/lib/gaia-paths.sh"
  )"

  [ "$artifacts" = "$expect_artifacts" ]
  [ "$memory" = "$expect_memory" ]
  [ "$artifacts" != "$memory" ]
}

@test "the probe root does not escape into the caller's environment" {
  run bash -c ". '$LIB' && gaia_tree_segments >/dev/null && printf '[%s]' \"\${PROJECT_ROOT:-}\""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a caller's own root is unchanged by the segment call" {
  run bash -c "PROJECT_ROOT='/caller/owned/root'; . '$LIB' && gaia_tree_segments >/dev/null && printf '%s' \"\$PROJECT_ROOT\""
  [ "$status" -eq 0 ]
  [ "$output" = "/caller/owned/root" ]
}

@test "the segment call leaves the caller's exported path variables alone" {
  run bash -c ". '$LIB' && gaia_tree_segments >/dev/null && printf '[%s]' \"\${GAIA_MEMORY_DIR:-}\""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "the segment function reports failure without emitting when the helper is absent" {
  # Copy the library somewhere with no paths helper beside it: resolution is
  # relative to the library's own directory, so the probe cannot resolve.
  mkdir -p "$TEST_TMP/orphan"
  cp "$LIB" "$TEST_TMP/orphan/gaia-tree-segments.sh"

  run bash -c ". '$TEST_TMP/orphan/gaia-tree-segments.sh' && gaia_tree_segments"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a failed segment probe does not exit the calling shell" {
  mkdir -p "$TEST_TMP/orphan2"
  cp "$LIB" "$TEST_TMP/orphan2/gaia-tree-segments.sh"

  # `set -e` plus an explicit continuation: the library must return, never
  # exit, so a caller can fall back or print its own diagnostic.
  run bash -c "set -euo pipefail; . '$TEST_TMP/orphan2/gaia-tree-segments.sh'; gaia_tree_segments || true; printf 'still-running'"
  [ "$status" -eq 0 ]
  [ "$output" = "still-running" ]
}
