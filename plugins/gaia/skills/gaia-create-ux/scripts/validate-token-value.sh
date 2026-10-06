#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# validate-token-value.sh — reject design-token values that would corrupt
# a CSS :root{} style block or escape into surrounding markup, and reject
# token names that are not valid CSS custom-property identifiers.
#
# Input: tab-separated name\tvalue lines on stdin (one per token).
# Output (stdout): accepted name\tvalue lines, unchanged.
# Diagnostics (stderr): one line per refused token naming the token and
# the reason.
#
# Exit 0 always — callers should check whether all expected tokens
# survived by comparing input/output counts.
#
# Bash 3.2 safe.

_vtv_refuse() {
  printf 'validate-token-value: refused "%s": %s\n' "$1" "$2" >&2
}

# _vtv_has_control VALUE — true when VALUE contains an ASCII control character
# (0x00-0x1F or 0x7F).  Non-ASCII bytes (>= 0x80, including UTF-8 multibyte
# sequences) are NOT control characters and are accepted.
_vtv_has_control() {
  # Delete every byte that is NOT a control character:
  #   printable ASCII 0x20-0x7E  — [:print:] under LC_ALL=C
  #   non-ASCII bytes 0x80-0xFF  — matched by the hex range
  # If anything remains, it is a control character.
  local stripped
  stripped="$(printf '%s' "$1" | tr -d '[:print:]\200-\377')"
  [ -n "$stripped" ]
}

# _vtv_valid_name NAME — true when NAME is a valid CSS custom-property
# identifier: starts with -- followed by one or more [A-Za-z0-9_-].
_vtv_valid_name() {
  case "$1" in
    --[A-Za-z0-9_-]*) ;;
    *) return 1 ;;
  esac
  # The case-match above accepts the prefix; now verify the full name
  # contains only allowed characters after the leading --.
  local suffix="${1#--}"
  local cleaned
  cleaned="$(printf '%s' "$suffix" | tr -d 'A-Za-z0-9_-')"
  [ -z "$cleaned" ]
}

# _vtv_check NAME VALUE — print the accepted line or refuse.
_vtv_check() {
  local name="$1" value="$2"

  # 0. Validate the token name (CSS custom-property identifier).
  if [ -z "$name" ]; then
    _vtv_refuse "(empty)" "token name is empty"
    return 0
  fi
  if ! _vtv_valid_name "$name"; then
    _vtv_refuse "$name" "invalid token name (must match --[A-Za-z0-9_-]+)"
    return 0
  fi

  # Empty value is accepted (a token can legitimately have no value yet).
  [ -n "$value" ] || { printf '%s\t%s\n' "$name" "$value"; return 0; }

  # 1. Reject values containing characters that would break a CSS block.
  local _bs=$'\\'
  case "$value" in
    *'<'*)      _vtv_refuse "$name" "contains <"; return 0 ;;
    *'>'*)      _vtv_refuse "$name" "contains >"; return 0 ;;
    *'{'*)      _vtv_refuse "$name" "contains {"; return 0 ;;
    *'}'*)      _vtv_refuse "$name" "contains }"; return 0 ;;
    *';'*)      _vtv_refuse "$name" "contains ;"; return 0 ;;
    *"$_bs"*)   _vtv_refuse "$name" "contains backslash"; return 0 ;;
  esac

  # 2. Reject </style in any letter case.  Defence in depth: the `<` case
  # above already catches any value containing `<`, so this branch is
  # unreachable under normal flow.  It is kept as a safety net in case the
  # case-match above is ever reordered or relaxed.
  if printf '%s' "$value" | grep -qi '</style'; then
    _vtv_refuse "$name" "contains </style sequence"
    return 0
  fi

  # 3. Reject control characters (ASCII 0x00-0x1F, 0x7F).
  #    Non-ASCII bytes (UTF-8, etc.) are accepted.
  if _vtv_has_control "$value"; then
    _vtv_refuse "$name" "contains control character"
    return 0
  fi

  # Accepted — emit unchanged.
  printf '%s\t%s\n' "$name" "$value"
}

# Main: read tab-separated name/value pairs from stdin.
# Use IFS= to preserve trailing tabs in values, then split on the first tab
# manually.  The trailing-line guard handles input that does not end with a
# newline: when read returns non-zero (EOF without newline), the last line is
# still in the variable if _line is non-empty.
while IFS= read -r _line || [ -n "$_line" ]; do
  # Skip blank lines.
  [ -n "$_line" ] || continue
  # Split on the first tab: name is before the first tab, value is everything
  # after it (including any further tabs).
  _name="${_line%%	*}"
  if [ "$_name" = "$_line" ]; then
    # No tab found — treat the whole line as the name with an empty value.
    _value=""
  else
    _value="${_line#*	}"
  fi
  _vtv_check "$_name" "$_value"
done
