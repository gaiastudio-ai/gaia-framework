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
# Single-pass, no subprocesses per token.  Bash 3.2 safe.

# _mtn_map_and_emit — single-pass main loop.
# All mapping, validation, and collision detection happens in pure bash
# with no subprocesses per token.  Collision tracking uses variable-name
# encoding (Bash 3.2 safe, no associative arrays needed).
_mtn_map_and_emit() {
  local raw name mapped ch i len suffix valid _enc _varname _prev_val

  while IFS= read -r raw || [ -n "$raw" ]; do
    # Strip trailing CR for CRLF tolerance.
    raw="${raw%$'\r'}"
    # Skip empty lines.
    [ -n "$raw" ] || continue

    name="$raw"

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
      printf 'map-token-name: refused "%s": %s\n' "$raw" "name is empty after stripping leading characters" >&2
      continue
    fi

    # Steps 3+4: replace dots and slashes with hyphens, collapse runs.
    # Walk character by character — no subprocesses, no regex on names.
    mapped=""
    len="${#name}"
    i=0
    while [ "$i" -lt "$len" ]; do
      ch="${name:$i:1}"
      case "$ch" in
        .|/|-)
          # Emit a hyphen only if the last character of mapped is not one.
          case "$mapped" in
            *-) ;;
            *)  mapped="${mapped}-" ;;
          esac
          ;;
        *)
          mapped="${mapped}${ch}"
          ;;
      esac
      i=$((i + 1))
    done

    # Step 4b: strip leading and trailing hyphens.
    while :; do
      case "$mapped" in
        -*) mapped="${mapped#-}" ;;
        *)  break ;;
      esac
    done
    while :; do
      case "$mapped" in
        *-) mapped="${mapped%-}" ;;
        *)  break ;;
      esac
    done

    if [ -z "$mapped" ]; then
      printf 'map-token-name: refused "%s": %s\n' "$raw" "name reduces to only hyphens after mapping" >&2
      continue
    fi

    # Step 5: add the -- prefix.
    mapped="--${mapped}"

    # Validate: must match --[A-Za-z0-9_][A-Za-z0-9_-]*.
    # Check prefix pattern.
    valid=true
    case "$mapped" in
      --[A-Za-z0-9_]*) ;;
      *) valid=false ;;
    esac

    # Check every character in the suffix is in [A-Za-z0-9_-].
    if "$valid"; then
      suffix="${mapped#--}"
      len="${#suffix}"
      i=0
      while [ "$i" -lt "$len" ]; do
        ch="${suffix:$i:1}"
        case "$ch" in
          [A-Za-z0-9_-]) ;;
          *) valid=false; break ;;
        esac
        i=$((i + 1))
      done
    fi

    if ! "$valid"; then
      printf 'map-token-name: refused "%s": mapped to "%s" which is not a valid CSS custom-property name\n' "$raw" "$mapped" >&2
      continue
    fi

    # Collision detection using variable-name encoding.
    # Encode the mapped suffix into a safe variable name.
    # Bijective: underscore -> __, hyphen -> _D, all other chars pass through.
    # The suffix is already validated to contain only [A-Za-z0-9_-].
    _enc=""
    suffix="${mapped#--}"
    len="${#suffix}"
    i=0
    while [ "$i" -lt "$len" ]; do
      ch="${suffix:$i:1}"
      case "$ch" in
        _) _enc="${_enc}__" ;;
        -) _enc="${_enc}_D" ;;
        *) _enc="${_enc}${ch}" ;;
      esac
      i=$((i + 1))
    done
    _varname="_mtn_s_${_enc}"

    # Check if we have already seen this mapped name.
    eval "_prev_val=\"\${${_varname}:-}\""
    if [ -n "$_prev_val" ]; then
      printf 'map-token-name: collision — "%s" and "%s" both map to "%s"; keeping the first\n' "$_prev_val" "$raw" "$mapped" >&2
      continue
    fi

    # Record: store the raw name in the variable.
    eval "${_varname}=\"\${raw}\""

    # Emit.
    printf '%s\t%s\n' "$mapped" "$raw"
  done
}

_mtn_map_and_emit
