#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# map-token-name.sh — map design-system token names to CSS custom-property form.
#
# Input: one raw token name per line on stdin (CRLF tolerant).
# Output (stdout): tab-separated mapped<TAB>original for accepted names.
# Diagnostics (stderr): one line per collision (second definition dropped)
#   and per refusal (name the validator would reject).
#
# Algorithm (applied to every name):
#   1. If the name starts with --, drop that prefix.
#   2. Strip any remaining leading dashes and dots.
#   3. Replace dots and slashes with hyphens.
#   4. Collapse runs of consecutive hyphens into one.
#   4b. Strip leading and trailing hyphens from the result.
#        If nothing remains, refuse.
#   5. Add the -- prefix.
#   Then validate: the result must match --[A-Za-z0-9_][A-Za-z0-9_-]*
#   (the first character after -- must not be a hyphen).
#
# Characters outside dots, slashes, letters, digits, underscore, and
# hyphen are not transformed; the resulting name fails the validator
# and is dropped with a stderr warning.
#
# Collision rule: when two raw names map to the same custom property,
# the first definition wins.  The collision is reported on stderr with
# both names listed.
#
# Refusal rule: when the mapped result fails validation (empty suffix,
# or characters outside [A-Za-z0-9_-]), it is dropped.  The refusal
# is reported on stderr.
#
# Refusal and collision diagnostics are printed to stderr and are
# visible in the terminal output at the end of the step.
#
# Bash 3.2 safe.  No awk regex on the names (tr + sed only).

_mtn_refuse() {
  printf 'map-token-name: refused "%s": %s\n' "$1" "$2" >&2
}

_mtn_collision() {
  printf 'map-token-name: collision — "%s" and "%s" both map to "%s"; keeping the first\n' "$1" "$2" "$3" >&2
}

# _mtn_valid NAME — true when NAME matches --[A-Za-z0-9_][A-Za-z0-9_-]*.
# The first character after -- must not be a hyphen.
_mtn_valid() {
  case "$1" in
    --[A-Za-z0-9_]*) ;;
    *) return 1 ;;
  esac
  local suffix="${1#--}"
  local cleaned
  cleaned="$(printf '%s' "$suffix" | tr -d 'A-Za-z0-9_-')"
  [ -z "$cleaned" ]
}

# _mtn_map RAW — print the mapped name to stdout, or return 1 on refusal.
_mtn_map() {
  local raw="$1"
  local name="$raw"

  # Step 1: if it starts with --, drop that prefix.
  case "$name" in
    --*) name="${name#--}" ;;
  esac

  # Step 2: strip remaining leading dashes and dots.
  while :; do
    case "$name" in
      [-.]*)  name="${name#?}" ;;
      *)      break ;;
    esac
  done

  # If nothing remains after stripping, refuse.
  if [ -z "$name" ]; then
    _mtn_refuse "$raw" "name is empty after stripping leading characters"
    return 1
  fi

  # Step 3: replace dots and slashes with hyphens.
  name="$(printf '%s' "$name" | tr './' '--')"

  # Step 4: collapse runs of consecutive hyphens into one.
  # Use sed for portability (no awk regex on the names).
  name="$(printf '%s' "$name" | sed 's/--*/-/g')"

  # Step 4b: strip leading and trailing hyphens from the result.
  # If nothing remains, refuse.
  while :; do
    case "$name" in
      -*) name="${name#-}" ;;
      *)  break ;;
    esac
  done
  while :; do
    case "$name" in
      *-) name="${name%-}" ;;
      *)  break ;;
    esac
  done
  if [ -z "$name" ]; then
    _mtn_refuse "$raw" "name reduces to only hyphens after mapping"
    return 1
  fi

  # Step 5: add the -- prefix.
  name="--${name}"

  # Validate.
  if ! _mtn_valid "$name"; then
    _mtn_refuse "$raw" "mapped to \"$name\" which is not a valid CSS custom-property name"
    return 1
  fi

  printf '%s' "$name"
}

# Track seen mapped names for collision detection.
# Bash 3.2: no associative arrays.  Use a temp file.
_seen_file=""
_cleanup() {
  [ -z "$_seen_file" ] || rm -f "$_seen_file"
}
trap _cleanup EXIT
_seen_file="$(mktemp "${TMPDIR:-/tmp}/mtn-seen.XXXXXX")"

while IFS= read -r _raw || [ -n "$_raw" ]; do
  # Strip trailing CR for CRLF tolerance.
  _raw="${_raw%$'\r'}"
  [ -n "$_raw" ] || continue

  _mapped="$(_mtn_map "$_raw")" || continue

  # Check for collisions.
  _prev="$(grep -F "	${_mapped}	" "$_seen_file" 2>/dev/null | head -1 || true)"
  if [ -n "$_prev" ]; then
    _prev_raw="${_prev%%	*}"
    _mtn_collision "$_prev_raw" "$_raw" "$_mapped"
    continue
  fi

  # Record.
  printf '%s\t%s\t\n' "$_raw" "$_mapped" >> "$_seen_file"

  # Emit.
  printf '%s\t%s\n' "$_mapped" "$_raw"
done
