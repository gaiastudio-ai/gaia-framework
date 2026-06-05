#!/usr/bin/env bash
# parse-bypass-flag.sh — Canonical `--bypass <skill> --reason "<text>"`
# argument parser for every gate-aware skill.
#
# Usage:
#   eval "$(scripts/lib/parse-bypass-flag.sh "$@")"
#
# When the original $@ contains a `--bypass` flag, this helper consumes
# `--bypass <skill> --reason "<text>"` from the argument vector and emits
# shell exports for the caller:
#
#   export BYPASS_SKILL="..."
#   export BYPASS_REASON="..."
#   set -- <remaining args>
#
# When `--bypass` is absent, it emits no-op exports:
#
#   export BYPASS_SKILL=""
#   export BYPASS_REASON=""
#   set -- <original args>
#
# Validation rules:
# - `--reason` is REQUIRED when `--bypass` is present (no anonymous bypasses).
# - Reason length MIN 10, MAX 500 chars.
# - Violations are reported via `echo` on stderr; the helper exits 1.

set -euo pipefail

declare -a __PASSTHRU=()
__BYPASS_SKILL=""
__BYPASS_REASON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bypass)
      if [ -z "${2:-}" ]; then
        printf '--bypass requires a skill argument\n' >&2
        exit 1
      fi
      __BYPASS_SKILL="$2"
      shift 2
      ;;
    --reason)
      if [ -z "${2:-}" ]; then
        printf '--reason requires text\n' >&2
        exit 1
      fi
      __BYPASS_REASON="$2"
      shift 2
      ;;
    *)
      __PASSTHRU+=("$1")
      shift
      ;;
  esac
done

# If --bypass present, require --reason and validate length.
if [ -n "$__BYPASS_SKILL" ]; then
  if [ -z "$__BYPASS_REASON" ]; then
    printf -- '--bypass requires --reason "<text>" (no anonymous bypasses)\n' >&2
    exit 1
  fi
  reason_len="${#__BYPASS_REASON}"
  if [ "$reason_len" -lt 10 ]; then
    printf -- '--reason must be at least 10 chars (got %d)\n' "$reason_len" >&2
    exit 1
  fi
  if [ "$reason_len" -gt 500 ]; then
    printf -- '--reason must be at most 500 chars (got %d)\n' "$reason_len" >&2
    exit 1
  fi
fi

# Emit shell exports for the caller to `eval`.
printf 'export BYPASS_SKILL=%q\n' "$__BYPASS_SKILL"
printf 'export BYPASS_REASON=%q\n' "$__BYPASS_REASON"
# Emit a set -- with remaining passthru args, properly quoted.
if [ "${#__PASSTHRU[@]}" -gt 0 ]; then
  printf 'set --'
  for a in "${__PASSTHRU[@]}"; do
    printf ' %q' "$a"
  done
  printf '\n'
else
  printf 'set --\n'
fi
