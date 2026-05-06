#!/usr/bin/env bash
# gaia-config-platform-edit.sh — E74-S11
#
# Comment-preserving editor for the top-level `platforms:` array in
# project-config.yaml. Subcommands: add, remove, list.
#
# Per ADR-081 §4.2, unknown identifiers warn (not error) but are accepted
# when they match the kebab-case shape `^[a-z][a-z0-9-]*$`. Empty or
# punctuated identifiers are rejected with exit 1.
#
# Usage:
#   gaia-config-platform-edit.sh --config <path> add <id>
#   gaia-config-platform-edit.sh --config <path> remove <id>
#   gaia-config-platform-edit.sh --config <path> list
#
# Idempotent: add of an existing id is a no-op; remove of an absent id is a
# no-op success.
#
# Exit codes:
#   0 success
#   1 invalid identifier or argument error

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="gaia-config-platform-edit.sh"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

CFG=""
CMD=""
ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || { err "--config requires a path"; exit 1; }
      CFG="$2"; shift 2 ;;
    --config=*)
      CFG="${1#--config=}"; shift ;;
    add|remove|list)
      CMD="$1"; shift
      if [ "$CMD" != "list" ]; then
        if [ $# -ge 1 ]; then ARG="$1"; shift; fi
      fi
      ;;
    -h|--help)
      sed -n '1,25p' "$0" >&2; exit 0 ;;
    *)
      err "unexpected argument: $1"; exit 1 ;;
  esac
done

[ -n "$CFG" ]  || { err "missing --config"; exit 1; }
[ -f "$CFG" ]  || { err "config not found: $CFG"; exit 1; }
[ -n "$CMD" ]  || { err "missing subcommand (add|remove|list)"; exit 1; }

KNOWN_PLATFORMS_RE='^(ios|android|web)$'
VALID_ID_RE='^[a-z][a-z0-9-]*$'

# Read the existing platforms[] (ordered, deduped).
_read_platforms() {
  awk '
    BEGIN { in_section=0 }
    /^platforms:[[:space:]]*$/ { in_section=1; next }
    in_section && /^[^[:space:]]/ { in_section=0 }
    in_section && /^[[:space:]]+-[[:space:]]+/ {
      v=$0; sub(/^[[:space:]]+-[[:space:]]+/, "", v);
      sub(/[[:space:]]*(#.*)?$/, "", v); gsub(/"/, "", v); print v
    }
  ' "$CFG"
}

# Replace or insert platforms section. Argument: newline-separated list.
_write_platforms() {
  local items="$1"
  local tmp; tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT

  if grep -qE '^platforms:[[:space:]]*$' "$CFG"; then
    # Replace via config-yaml-editor.sh
    {
      printf 'platforms:\n'
      if [ -n "$items" ]; then
        printf '%s\n' "$items" | sed 's/^/  - /'
      fi
    } > "$tmp"
    "$(dirname "$0")/config-yaml-editor.sh" replace "$CFG" platforms "$tmp"
  else
    {
      printf 'platforms:\n'
      if [ -n "$items" ]; then
        printf '%s\n' "$items" | sed 's/^/  - /'
      fi
    } > "$tmp"
    "$(dirname "$0")/config-yaml-editor.sh" insert "$CFG" platforms "$tmp"
  fi
  trap - EXIT
  rm -f "$tmp"
}

case "$CMD" in
  list)
    _read_platforms
    ;;
  add)
    [ -n "$ARG" ] || { err "add requires a platform id"; exit 1; }
    if ! printf '%s' "$ARG" | grep -Eq "$VALID_ID_RE"; then
      err "invalid platform id: '$ARG' (expected $VALID_ID_RE)"
      exit 1
    fi
    if ! printf '%s' "$ARG" | grep -Eq "$KNOWN_PLATFORMS_RE"; then
      err "warning: unknown platform '$ARG' (per ADR-081 §4.2 — proceeding)"
    fi
    cur="$(_read_platforms || true)"
    if printf '%s\n' "$cur" | grep -Fxq "$ARG"; then
      # Already present — idempotent no-op.
      exit 0
    fi
    new="$(printf '%s\n%s\n' "$cur" "$ARG" | awk 'NF')"
    _write_platforms "$new"
    ;;
  remove)
    [ -n "$ARG" ] || { err "remove requires a platform id"; exit 1; }
    cur="$(_read_platforms || true)"
    new="$(printf '%s\n' "$cur" | awk -v t="$ARG" 'NF && $0 != t')"
    _write_platforms "$new"
    ;;
  *)
    err "unknown subcommand: $CMD"; exit 1 ;;
esac
