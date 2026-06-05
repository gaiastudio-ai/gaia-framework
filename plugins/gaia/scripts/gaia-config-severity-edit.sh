#!/usr/bin/env bash
# gaia-config-severity-edit.sh — comment-preserving editor for the `severity:` map
#
# Edits the top-level `severity:` map in project-config.yaml, supporting
# 5-into-3 severity mapping:
#
#   Critical | High | Medium | Low | Info
#       ↓        ↓       ↓      ↓     ↓
#         BLOCKED | REQUEST_CHANGES | APPROVE
#
# Subcommands:
#   set <internal> <verdict>   — set / replace a single mapping
#   show                       — print the current map (one line per entry)
#   clear                      — remove the section entirely
#
# Usage:
#   gaia-config-severity-edit.sh --config <path> set Critical BLOCKED
#   gaia-config-severity-edit.sh --config <path> show
#   gaia-config-severity-edit.sh --config <path> clear
#
# Exit codes:
#   0 success
#   1 invalid argument, unknown internal/verdict, or I/O error

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="gaia-config-severity-edit.sh"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

CFG=""
CMD=""
ARG1=""
ARG2=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || { err "--config requires a path"; exit 1; }
      CFG="$2"; shift 2 ;;
    --config=*)
      CFG="${1#--config=}"; shift ;;
    set|show|clear)
      CMD="$1"; shift
      if [ "$CMD" = "set" ]; then
        if [ $# -ge 1 ]; then ARG1="$1"; shift; fi
        if [ $# -ge 1 ]; then ARG2="$1"; shift; fi
      fi
      ;;
    -h|--help)
      sed -n '1,30p' "$0" >&2; exit 0 ;;
    *)
      err "unexpected argument: $1"; exit 1 ;;
  esac
done

[ -n "$CFG" ] || { err "missing --config"; exit 1; }
[ -f "$CFG" ] || { err "config not found: $CFG"; exit 1; }
[ -n "$CMD" ] || { err "missing subcommand (set|show|clear)"; exit 1; }

VALID_INTERNALS_RE='^(Critical|High|Medium|Low|Info)$'
VALID_VERDICTS_RE='^(BLOCKED|REQUEST_CHANGES|APPROVE)$'

EDITOR_SH="$(dirname "$0")/config-yaml-editor.sh"

# Read the current severity map as "name verdict" pairs (one per line).
_read_severity() {
  awk '
    BEGIN { in_section=0 }
    /^severity:[[:space:]]*$/ { in_section=1; next }
    in_section && /^[^[:space:]]/ { in_section=0 }
    in_section && /^[[:space:]]+[A-Za-z][A-Za-z0-9]*:[[:space:]]/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      name=line; sub(/:.*/, "", name)
      val=line; sub(/^[^:]+:[[:space:]]*/, "", val)
      sub(/[[:space:]]*(#.*)?$/, "", val); gsub(/"/, "", val)
      print name, val
    }
  ' "$CFG"
}

# Write back the severity section using config-yaml-editor.sh replace/insert.
# Argument: newline-separated "name verdict" lines.
_write_severity() {
  local pairs="$1"
  local tmp; tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT

  {
    printf 'severity:\n'
    if [ -n "$pairs" ]; then
      printf '%s\n' "$pairs" | awk 'NF { printf "  %s: %s\n", $1, $2 }'
    fi
  } > "$tmp"

  if grep -qE '^severity:[[:space:]]*$' "$CFG"; then
    "$EDITOR_SH" replace "$CFG" severity "$tmp"
  else
    "$EDITOR_SH" insert "$CFG" severity "$tmp"
  fi

  trap - EXIT
  rm -f "$tmp"
}

case "$CMD" in
  show)
    cur="$(_read_severity || true)"
    if [ -z "$cur" ]; then
      echo "no severity section"
    else
      printf '%s\n' "$cur"
    fi
    ;;

  clear)
    if ! grep -qE '^severity:[[:space:]]*$' "$CFG"; then
      # Section absent — no-op success.
      exit 0
    fi
    # Replace the section with an empty placeholder and then strip it via sed.
    # The simpler approach: rewrite the file without the severity block via awk.
    tmp="$(mktemp)"
    awk '
      BEGIN { in_section=0 }
      /^severity:[[:space:]]*$/ { in_section=1; next }
      in_section {
        # Inside the section: skip indented and blank lines until next top-level key.
        if ($0 ~ /^[a-z_][a-z0-9_]*:/) {
          in_section=0
          print
        }
        next
      }
      { print }
    ' "$CFG" > "$tmp"
    mv "$tmp" "$CFG"
    ;;

  set)
    [ -n "$ARG1" ] || { err "set requires <internal> <verdict>"; exit 1; }
    [ -n "$ARG2" ] || { err "set requires <internal> <verdict>"; exit 1; }
    if ! printf '%s' "$ARG1" | grep -Eq "$VALID_INTERNALS_RE"; then
      err "unknown internal severity: '$ARG1' (expected one of Critical|High|Medium|Low|Info)"
      exit 1
    fi
    if ! printf '%s' "$ARG2" | grep -Eq "$VALID_VERDICTS_RE"; then
      err "unknown verdict: '$ARG2' (expected one of BLOCKED|REQUEST_CHANGES|APPROVE)"
      exit 1
    fi
    cur="$(_read_severity || true)"
    # Replace or append the entry for ARG1.
    new="$(printf '%s\n%s %s\n' "$cur" "$ARG1" "$ARG2" \
      | awk 'NF { last[$1]=$2 } END { for (k in last) print k, last[k] }' \
      | sort)"
    _write_severity "$new"
    ;;

  *)
    err "unknown subcommand: $CMD"; exit 1 ;;
esac
