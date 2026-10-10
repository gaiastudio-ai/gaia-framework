#!/usr/bin/env bash
# derive-design-scope.sh — classify changed spec paths into a publication
# scope: design-system, product-design, or both.
#
# Usage:
#   derive-design-scope.sh [--spec-root <dir>] <path>...
#
# Each positional argument is a spec-relative path. The script strips a
# leading ./ and converts absolute paths under --spec-root to relative
# before classifying. Paths are classified by their first directory
# component:
#
#   tokens/, components/, templates/ -> design-system
#   screens/, flows/                 -> product-design
#   anything else                    -> both (unclassified)
#
# A mix of design-system and product-design paths produces both.
# No arguments produces both.
#
# Output: one word on stdout (design-system, product-design, or both).

set -euo pipefail
LC_ALL=C; export LC_ALL

_spec_root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec-root) _spec_root="$2"; shift 2 ;;
    *) break ;;
  esac
done

if [ $# -eq 0 ]; then
  printf 'both\n'
  exit 0
fi

_has_ds=0
_has_pd=0

for _path in "$@"; do
  # Strip leading ./
  _path="${_path#./}"
  # Convert absolute path under spec root to relative
  if [ -n "$_spec_root" ]; then
    case "$_path" in
      "${_spec_root}/"*) _path="${_path#"${_spec_root}/"}" ;;
    esac
  fi
  case "$_path" in
    tokens/*|components/*|templates/*) _has_ds=1 ;;
    screens/*|flows/*)                 _has_pd=1 ;;
    *)                                 _has_ds=1; _has_pd=1 ;;
  esac
done

if [ "$_has_ds" -eq 1 ] && [ "$_has_pd" -eq 1 ]; then
  printf 'both\n'
elif [ "$_has_ds" -eq 1 ]; then
  printf 'design-system\n'
else
  printf 'product-design\n'
fi
