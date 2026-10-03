#!/usr/bin/env bash
# safe-filename.sh — shared safety checks for filenames and hashes.
#
# Provides:
#   SAFE_FILENAME_JQ_DEF  — jq def string; paste inside a jq program
#   SAFE_HASH_JQ_DEF      — jq def string; paste inside a jq program
#   safe_filename_check()  — shell-side filename validation (arg, not stdin)
#
# jq defs reject the entire run on the first unsafe value (jq error()),
# so downstream processing never sees a crafted entry.
#
# Hash rule: non-empty, no control characters (0x00-0x1f, 0x7f).
# This is deliberately NOT hex-only — real hashes may contain any
# printable character. The check catches newline/tab injection that
# would forge TSV rows or plan lines.
#
# Bash 3.2 safe: no associative arrays, no mapfile.

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------------------------------------------------------------------------
# jq def: safe_filename
# ---------------------------------------------------------------------------
# Rejects: empty, absolute (/), traversal (..), dot-segment (.),
# trailing slash, empty segment (//), control characters.
# Each rejection class has a distinct diagnostic substring.
# Usage inside jq: $SAFE_FILENAME_JQ_DEF .file | safe_filename
#
# shellcheck disable=SC2034
SAFE_FILENAME_JQ_DEF='
  def safe_filename:
    . as $f |
    if ($f | length) == 0 then error("unsafe filename: empty")
    elif ($f | startswith("/")) then error("unsafe filename (absolute): " + ($f | @json))
    elif ($f | test("(^|/)\\.\\.(/|$)")) then error("unsafe filename (traversal): " + ($f | @json))
    elif ($f | test("(^|/)\\.(/|$)")) then error("unsafe filename (dot-segment): " + ($f | @json))
    elif ($f | test("/$")) then error("unsafe filename (trailing slash): " + ($f | @json))
    elif ($f | test("//")) then error("unsafe filename (empty segment): " + ($f | @json))
    elif ($f | test("[\\x00-\\x1f\\x7f]")) then error("unsafe filename (control char): " + ($f | @json))
    else .
    end;
'

# ---------------------------------------------------------------------------
# jq def: safe_hash
# ---------------------------------------------------------------------------
# Rejects: empty, any control character (0x00-0x1f, 0x7f).
# Usage inside jq: $SAFE_HASH_JQ_DEF .hash | safe_hash
#
# shellcheck disable=SC2034
SAFE_HASH_JQ_DEF='
  def safe_hash:
    . as $h |
    if ($h | type) != "string" then error("unsafe hash: not a string")
    elif ($h | length) == 0 then error("unsafe hash: empty")
    elif ($h | test("[\\x00-\\x1f\\x7f]")) then error("unsafe hash (control char): " + ($h | @json))
    else .
    end;
'

# ---------------------------------------------------------------------------
# Shell-side filename check
# ---------------------------------------------------------------------------
# Same rules as the jq def but for values that never pass through jq/TSV.
# Returns 0 on safe, 1 on unsafe (with diagnostic on stderr).
safe_filename_check() {
  local f="${1:-}"
  if [ -z "$f" ]; then
    printf 'unsafe filename: empty\n' >&2
    return 1
  fi
  case "$f" in
    /*) printf 'unsafe filename (absolute): %s\n' "$f" >&2; return 1 ;;
  esac
  # Traversal: ../ or /../ or /.. at end or bare ..
  case "$f" in
    ..|../*|*/../*|*/..) printf 'unsafe filename (traversal): %s\n' "$f" >&2; return 1 ;;
  esac
  # Dot-segment: ./ or /./ or /. at end or bare .
  case "$f" in
    .|./*|*/./*|*/.) printf 'unsafe filename (dot-segment): %s\n' "$f" >&2; return 1 ;;
  esac
  # Trailing slash
  case "$f" in
    */) printf 'unsafe filename (trailing slash): %s\n' "$f" >&2; return 1 ;;
  esac
  # Empty segment (//)
  case "$f" in
    *//*) printf 'unsafe filename (empty segment): %s\n' "$f" >&2; return 1 ;;
  esac
  # Control characters (0x00-0x1f, 0x7f) — use case glob, no subprocess
  # shellcheck disable=SC2254
  case "$f" in
    *[[:cntrl:]]*)
      printf 'unsafe filename (control char): %s\n' "$f" >&2
      return 1
      ;;
  esac
  return 0
}
