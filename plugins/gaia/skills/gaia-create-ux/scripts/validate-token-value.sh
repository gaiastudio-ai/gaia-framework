#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# validate-token-value.sh — reject design-token values that would corrupt
# a CSS :root{} style block or escape into surrounding markup.
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

# _vtv_has_control VALUE — true when VALUE contains a control character
# (ASCII 0x00-0x1F or 0x7F), including newline, tab, etc.
_vtv_has_control() {
  # Strip all printable ASCII (0x20-0x7E).  If anything remains, the
  # value contained a control character.
  local stripped
  stripped="$(printf '%s' "$1" | tr -d '[:print:]')"
  [ -n "$stripped" ]
}

# _vtv_check NAME VALUE — print the accepted line or refuse.
_vtv_check() {
  local name="$1" value="$2"

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

  # 2. Reject </style in any letter case.
  if printf '%s' "$value" | grep -qi '</style'; then
    _vtv_refuse "$name" "contains </style sequence"
    return 0
  fi

  # 3. Reject control characters.
  if _vtv_has_control "$value"; then
    _vtv_refuse "$name" "contains control character"
    return 0
  fi

  # Accepted — emit unchanged.
  printf '%s\t%s\n' "$name" "$value"
}

# Main: read tab-separated name/value pairs from stdin.
# The trailing-line guard handles input that does not end with a newline:
# when read returns non-zero (EOF without newline), the last line is still
# in the variable if _name is non-empty.
while IFS=$'\t' read -r _name _value || [ -n "$_name" ]; do
  # Skip blank lines.
  [ -n "$_name" ] || continue
  _vtv_check "$_name" "$_value"
done
