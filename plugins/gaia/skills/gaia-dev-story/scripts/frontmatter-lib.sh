#!/usr/bin/env bash
# frontmatter-lib.sh — shared YAML-frontmatter parser for gaia-dev-story
#
# Purpose:
#   Three scripts in skills/gaia-dev-story/scripts/ each carry an identical
#   awk-based frontmatter slicer plus a `get_field` helper:
#     - story-parse.sh
#     - pr-body.sh
#     - commit-msg.sh
#   This lib extracts the shared implementation so behavior changes ripple
#   through one file instead of three.
#
# Public functions:
#   fm_slice <path>          — write the YAML frontmatter block (lines between
#                              the first two `---` markers) to stdout. Returns
#                              non-zero with a canonical error if the block is
#                              malformed (missing opening marker, missing
#                              closing marker, or file not found).
#
#   fm_get_field <name>      — read a single key from a frontmatter block on
#                              stdin and write its value to stdout. Strips
#                              surrounding double or single quotes. Empty
#                              output for missing keys (exit 0).
#
# This file is sourced — not invoked directly. It MUST NOT call `set -e` or
# similar global mode flags so callers retain their own shell state.

# Slice: emit the frontmatter block on stdout. Returns 1 on any error.
fm_slice() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    printf 'frontmatter-lib: fm_slice: missing path argument\n' >&2
    return 1
  fi
  if [ ! -f "$path" ]; then
    printf 'frontmatter-lib: fm_slice: file not found: %s\n' "$path" >&2
    return 1
  fi
  awk '
    BEGIN { state = 0 }
    {
      # Strip optional CR for CRLF tolerance
      line = $0
      sub(/\r$/, "", line)
      if (state == 0 && line == "---") { state = 1; next }
      if (state == 1 && line == "---") { state = 2; exit }
      if (state == 1) { print line }
    }
    END {
      if (state != 2) exit 1
    }
  ' "$path" || {
    printf 'frontmatter-lib: fm_slice: malformed frontmatter (unbalanced --- markers): %s\n' "$path" >&2
    return 1
  }
  return 0
}

# Get a single field from a frontmatter block read on stdin. Strips
# surrounding double or single quotes. Outputs empty string for missing
# fields and returns 0 (absence is not an error here — callers decide
# whether a missing field should be fatal).
fm_get_field() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    printf 'frontmatter-lib: fm_get_field: missing key argument\n' >&2
    return 1
  fi
  awk -v key="$key" '
    {
      # Strip optional CR for CRLF tolerance
      line = $0
      sub(/\r$/, "", line)
      if (match(line, "^[[:space:]]*" key "[[:space:]]*:[[:space:]]*")) {
        rest = substr(line, RSTART + RLENGTH)
        sub(/[[:space:]]+$/, "", rest)
        n = length(rest)
        if (n >= 2 && substr(rest, 1, 1) == "\"" && substr(rest, n, 1) == "\"") {
          print substr(rest, 2, n - 2); exit
        }
        if (n >= 2 && substr(rest, 1, 1) == "'"'"'" && substr(rest, n, 1) == "'"'"'") {
          print substr(rest, 2, n - 2); exit
        }
        print rest; exit
      }
    }
  '
}
