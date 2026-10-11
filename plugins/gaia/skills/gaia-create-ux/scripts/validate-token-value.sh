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
# Single-pass, no subprocesses per token.  Bash 3.2 safe.

# Build a literal string of all ASCII control bytes (0x01-0x1F, 0x7F) once.
# NUL (0x00) cannot exist in a bash variable and is implicitly excluded.
# This string is used in a case pattern to detect control characters
# without subprocesses and without printf %d (which gives negative values
# for high bytes under Bash 3.2).
_VTV_CTRL="$(printf '\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177')"

# _vtv_process — single-pass main loop.
# All validation happens in pure bash character walks.
# No dynamic string is ever used as a regex.
_vtv_process() {
  local _line _name _value ch i len suffix _lower _refused _reason

  while IFS= read -r _line || [ -n "$_line" ]; do
    # Skip blank lines.
    [ -n "$_line" ] || continue

    # Split on the first tab: name is before, value is everything after.
    _name="${_line%%	*}"
    if [ "$_name" = "$_line" ]; then
      _value=""
    else
      _value="${_line#*	}"
    fi

    # 0. Validate the token name (CSS custom-property identifier).
    if [ -z "$_name" ]; then
      printf 'validate-token-value: refused "(empty)": token name is empty\n' >&2
      continue
    fi

    # Name must start with -- followed by [A-Za-z0-9_-].
    _refused=false
    case "$_name" in
      --[A-Za-z0-9_-]*) ;;
      *) _refused=true ;;
    esac

    # Check every character in the suffix is in [A-Za-z0-9_-].
    if ! "$_refused"; then
      suffix="${_name#--}"
      len="${#suffix}"
      i=0
      while [ "$i" -lt "$len" ]; do
        ch="${suffix:$i:1}"
        case "$ch" in
          [A-Za-z0-9_-]) ;;
          *) _refused=true; break ;;
        esac
        i=$((i + 1))
      done
    fi

    if "$_refused"; then
      printf 'validate-token-value: refused "%s": invalid token name (must match --[A-Za-z0-9_-]+)\n' "$_name" >&2
      continue
    fi

    # Empty value is accepted.
    if [ -z "$_value" ]; then
      printf '%s\t%s\n' "$_name" "$_value"
      continue
    fi

    # 1+2+3. Check every character in the value.
    # Refused characters: < > { } ; \
    # Control characters: 0x00-0x1F and 0x7F.
    # All checked in a single character walk — no subprocesses.
    _refused=false
    _reason=""
    len="${#_value}"
    i=0
    while [ "$i" -lt "$len" ]; do
      ch="${_value:$i:1}"

      # Check for the six refused characters.
      case "$ch" in
        '<') _refused=true; _reason="contains <"; break ;;
        '>') _refused=true; _reason="contains >"; break ;;
        '{') _refused=true; _reason="contains {"; break ;;
        '}') _refused=true; _reason="contains }"; break ;;
        ';') _refused=true; _reason="contains ;"; break ;;
        \\*) _refused=true; _reason="contains backslash"; break ;;
      esac

      # Check for control characters (0x00-0x1F, 0x7F).
      # Uses a prebuilt literal string of all control bytes so the test
      # is purely byte-based — works identically under Bash 3.2 and 5.
      # Non-ASCII bytes (>= 0x80, including UTF-8 sequences) are allowed.
      case "$ch" in
        *["$_VTV_CTRL"]*)
          _refused=true
          _reason="contains control character"
          break
          ;;
      esac

      i=$((i + 1))
    done

    # Defence in depth: check </style in any case.
    # The < check above catches it, but this is a safety net.
    if ! "$_refused" && [ "${#_value}" -ge 7 ]; then
      _lower=""
      len="${#_value}"
      i=0
      while [ "$i" -lt "$len" ]; do
        ch="${_value:$i:1}"
        case "$ch" in
          A) _lower="${_lower}a" ;; B) _lower="${_lower}b" ;;
          C) _lower="${_lower}c" ;; D) _lower="${_lower}d" ;;
          E) _lower="${_lower}e" ;; F) _lower="${_lower}f" ;;
          G) _lower="${_lower}g" ;; H) _lower="${_lower}h" ;;
          I) _lower="${_lower}i" ;; J) _lower="${_lower}j" ;;
          K) _lower="${_lower}k" ;; L) _lower="${_lower}l" ;;
          M) _lower="${_lower}m" ;; N) _lower="${_lower}n" ;;
          O) _lower="${_lower}o" ;; P) _lower="${_lower}p" ;;
          Q) _lower="${_lower}q" ;; R) _lower="${_lower}r" ;;
          S) _lower="${_lower}s" ;; T) _lower="${_lower}t" ;;
          U) _lower="${_lower}u" ;; V) _lower="${_lower}v" ;;
          W) _lower="${_lower}w" ;; X) _lower="${_lower}x" ;;
          Y) _lower="${_lower}y" ;; Z) _lower="${_lower}z" ;;
          *)     _lower="${_lower}${ch}" ;;
        esac
        i=$((i + 1))
      done
      case "$_lower" in
        *'</style'*)
          _refused=true
          _reason="contains </style sequence"
          ;;
      esac
    fi

    if "$_refused"; then
      printf 'validate-token-value: refused "%s": %s\n' "$_name" "$_reason" >&2
      continue
    fi

    # Accepted — emit unchanged.
    printf '%s\t%s\n' "$_name" "$_value"
  done
}

_vtv_process
