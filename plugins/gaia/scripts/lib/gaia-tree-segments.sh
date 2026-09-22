#!/usr/bin/env bash
# gaia-tree-segments.sh — recover the runtime tree's own path segments.
#
# Scripts that compose an output path from a caller-supplied root need the
# tree segment (`.gaia/artifacts`, `.gaia/memory`) without the root attached.
# Sourcing the paths helper directly does not give them that: with no root in
# the environment it walks up from the working directory, so a script called
# with its own `--root` would silently resolve a tree the caller never named,
# and a script producing relative output would start producing absolute paths.
#
# So the helper is sourced in a subshell pinned to a sentinel root, and the
# sentinel is stripped back off. What comes out is the segment alone — the
# caller keeps its own root resolution untouched and appends its own leaf.
#
# Usage:
#   . "<plugin-root>/scripts/lib/gaia-tree-segments.sh"
#   { IFS= read -r ARTIFACTS_SEGMENT; IFS= read -r MEMORY_SEGMENT; } \
#     < <(gaia_tree_segments || true)
#   [ -n "$ARTIFACTS_SEGMENT" ] || die "could not resolve the runtime tree"
#
# Emits two lines on stdout — the artifacts segment, then the memory segment —
# and returns non-zero without emitting when the helper cannot be resolved.
# Callers decide whether that is fatal; this library never exits the shell.

# gaia_tree_segments — print the artifacts and memory tree segments.
gaia_tree_segments() {
  local lib _sentinel
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gaia-paths.sh"
  [ -r "$lib" ] || return 1
  _sentinel="/gaia-path-segment-probe"
  (
    # The subshell is the point: the probe root must not escape into the
    # caller's environment, which still owns its own root resolution. The
    # assignment is read by the helper sourced below, not by this library.
    # shellcheck disable=SC2030,SC2034
    PROJECT_ROOT="$_sentinel"
    _GAIA_PATHS_LOADED=""
    # shellcheck source=./gaia-paths.sh
    # shellcheck disable=SC1091  # resolved at runtime from the plugin root.
    . "$lib" >/dev/null 2>&1 || exit 1
    [ -n "${GAIA_ARTIFACTS_DIR:-}" ] && [ -n "${GAIA_MEMORY_DIR:-}" ] || exit 1
    printf '%s\n%s\n' \
      "${GAIA_ARTIFACTS_DIR#"$_GAIA_ROOT_CANON"/}" \
      "${GAIA_MEMORY_DIR#"$_GAIA_ROOT_CANON"/}"
  )
}
