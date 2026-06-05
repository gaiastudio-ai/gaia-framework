#!/usr/bin/env bash
# scratchpad-allocate.sh — gaia-meeting scratchpad allocator
#
# Maintains an in-memory (file-backed) scratchpad data model:
#   - Append-only monotonic SP-N allocation
#   - Latest-wins replace at an existing SP-N (with history_count bookkeeping)
#   - Render the latest-wins block for per-turn agent context
#
# Storage format (one record per line; pipe-delimited):
#   SP-N|content|content_type|pinning_agent|intent|history_count
#
# Subcommands:
#   pin    Append a new pin or replace an existing SP-N (latest-wins).
#   list   Emit one field per record in pin order: --field {id|content|content_type|pinning_agent|intent|history_count}
#   render Emit a human-readable block (one line per SP-N) for agent context.
#
# Exit codes:
#   0 = success
#   2 = invalid args / missing/unknown SP-N target
#   3 = state-file I/O error

set -euo pipefail
LC_ALL=C
export LC_ALL

usage() {
  cat >&2 <<'USAGE'
Usage:
  scratchpad-allocate.sh pin --state <file> [--target SP-N] --content <s> --intent <s> --agent <s> [--content-type <s>]
  scratchpad-allocate.sh list --state <file> --field {id|content|content_type|pinning_agent|intent|history_count}
  scratchpad-allocate.sh render --state <file>
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

cmd="$1"; shift

# Pipe-delimited record encoder/decoder. Newlines in content are converted to
# literal '\n' so each record stays single-line; pipes are URL-style escaped.
_encode() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//|/%7C}"
  # Convert literal newlines to '\n' (two-byte sequence)
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

_decode() {
  local s="$1"
  s="${s//%0A/$'\n'}"
  s="${s//%7C/|}"
  s="${s//%25/%}"
  printf '%s' "$s"
}

cmd_pin() {
  local state="" target="" content="" intent="" agent="" ctype=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state)        state="$2"; shift 2 ;;
      --target)       target="$2"; shift 2 ;;
      --content)      content="$2"; shift 2 ;;
      --intent)       intent="$2"; shift 2 ;;
      --agent)        agent="$2"; shift 2 ;;
      --content-type) ctype="$2"; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done
  if [[ -z "$state" ]]; then
    echo "scratchpad-allocate.sh: --state required" >&2
    exit 2
  fi
  [[ -f "$state" ]] || : > "$state"

  if [[ -n "$target" ]]; then
    # Replace at existing SP-N (latest-wins). Record must already exist.
    if ! grep -q "^${target}|" "$state"; then
      echo "scratchpad-allocate.sh: target ${target} not found in state" >&2
      exit 2
    fi
    local tmp; tmp="$(mktemp)"
    local replaced=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local id rest
      id="${line%%|*}"
      rest="${line#*|}"
      if [[ "$id" == "$target" ]]; then
        # bump history_count (last field)
        local hc="${rest##*|}"
        hc=$((hc + 1))
        printf '%s|%s|%s|%s|%s|%s\n' \
          "$id" \
          "$(_encode "$content")" \
          "$(_encode "${ctype:-md}")" \
          "$(_encode "$agent")" \
          "$(_encode "$intent")" \
          "$hc" >> "$tmp"
        replaced=1
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$state"
    if [[ "$replaced" -ne 1 ]]; then
      echo "scratchpad-allocate.sh: target ${target} not replaced (state corruption)" >&2
      rm -f "$tmp"
      exit 2
    fi
    mv "$tmp" "$state"
    printf '%s\n' "$target"
    return 0
  fi

  # Allocate the next monotonic SP-N (max existing + 1, or 1 when empty)
  local max=0
  if [[ -s "$state" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local id="${line%%|*}"
      local n="${id#SP-}"
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n > max )); then
        max=$n
      fi
    done < "$state"
  fi
  local next=$((max + 1))
  local id="SP-${next}"
  printf '%s|%s|%s|%s|%s|%s\n' \
    "$id" \
    "$(_encode "$content")" \
    "$(_encode "${ctype:-md}")" \
    "$(_encode "$agent")" \
    "$(_encode "$intent")" \
    0 >> "$state"
  printf '%s\n' "$id"
}

cmd_list() {
  local state="" field=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      --field) field="$2"; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done
  if [[ -z "$state" || -z "$field" ]]; then
    echo "scratchpad-allocate.sh list: --state and --field required" >&2
    exit 2
  fi
  [[ -f "$state" ]] || return 0
  while IFS='|' read -r id content ctype agent intent hc; do
    [[ -z "$id" ]] && continue
    case "$field" in
      id)             printf '%s\n' "$id" ;;
      content)        printf '%s\n' "$(_decode "$content")" ;;
      content_type)   printf '%s\n' "$(_decode "$ctype")" ;;
      pinning_agent)  printf '%s\n' "$(_decode "$agent")" ;;
      intent)         printf '%s\n' "$(_decode "$intent")" ;;
      history_count)  printf '%s\n' "$hc" ;;
      *) echo "scratchpad-allocate.sh list: unknown --field $field" >&2; exit 2 ;;
    esac
  done < "$state"
}

cmd_render() {
  local state=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done
  if [[ -z "$state" ]]; then
    echo "scratchpad-allocate.sh render: --state required" >&2
    exit 2
  fi
  [[ -f "$state" ]] || return 0
  while IFS='|' read -r id content ctype agent intent hc; do
    [[ -z "$id" ]] && continue
    printf '%s: %s\n' "$id" "$(_decode "$content")"
  done < "$state"
}

case "$cmd" in
  pin)    cmd_pin    "$@" ;;
  list)   cmd_list   "$@" ;;
  render) cmd_render "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
