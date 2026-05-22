#!/usr/bin/env bash
# discover-stories.sh — /gaia-atdd batch discovery (E46-S3)
#
# Scans .gaia/artifacts/planning-artifacts/epics-and-stories.md for high-risk stories
# and emits either the keys list or a [all / select / skip] menu. Powers
# the argumentless invocation branch of /gaia-atdd (FR-351, VCP-ATDD-01..05).
#
# Usage:
#   discover-stories.sh --epics <path> --format=keys[,menu] [--select=N,M,...]
#
# Options:
#   --epics <path>      Path to epics-and-stories.md (required)
#   --format=keys       Emit one story key per line, in declared order
#   --format=menu       Emit a numbered menu with key, title, risk + selection
#                       options ([all / select / skip], or [all / skip] for
#                       a single story per AC-EC7).
#   --select=N,M,...    Restrict the keys output to the chosen 1-based indices
#                       (used by the 'select' branch — AC3 / VCP-ATDD-03).
#                       Invalid (out-of-range or non-numeric) entries cause a
#                       non-zero exit with "Invalid selection" (AC-EC6).
#
# Exit codes:
#   0  success (including the empty-list graceful exit, AC5 / VCP-ATDD-05)
#   1  unrecoverable error (missing epics file, invalid selection, etc.)
#
# POSIX discipline: bash with [[ ]] only; macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-atdd/discover-stories.sh"

# ---------- Argument parsing ----------

_die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

_EPICS=""
_FORMAT="keys"
_SELECT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --epics) _EPICS="${2:-}"; shift 2 ;;
    --epics=*) _EPICS="${1#--epics=}"; shift ;;
    --format) _FORMAT="${2:-}"; shift 2 ;;
    --format=*) _FORMAT="${1#--format=}"; shift ;;
    --select) _SELECT="${2:-}"; shift 2 ;;
    --select=*) _SELECT="${1#--select=}"; shift ;;
    --help|-h)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) _die "unknown argument: $1" ;;
  esac
done

[ -n "$_EPICS" ] || _die "--epics is required"

if [ ! -f "$_EPICS" ] || [ ! -r "$_EPICS" ]; then
  printf 'Cannot read %s — halting\n' "$_EPICS"
  exit 1
fi

# ---------- Parse high-risk stories from the epics-and-stories.md table ----------
#
# Expected row shape (whitespace tolerant):
#   | E{n}-S{m} | Title | Size | Priority | Risk |
#
# We only emit rows whose final pipe-separated cell is exactly "high" (per the
# Dev Notes: "Filter on exact risk: high value"). Header rows (containing
# "---" or "Risk") are skipped.

_parse_high_risk() {
  awk -F'|' '
    {
      # Strip leading/trailing whitespace from each cell
      for (i = 1; i <= NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      }
      # A valid story row has at least: empty | key | title | size | priority | risk | empty
      if (NF < 6) next
      key   = $2
      title = $3
      risk  = $(NF - 1)
      # Skip headers and divider rows
      if (key == "" || key == "Key" || key ~ /^-+$/) next
      if (risk != "high") next
      # Story key must look like E{n}-S{m} (or E{n}-Anything — keep flexible)
      if (key !~ /^E[0-9]+-/) next
      print key "\t" title "\t" risk
    }
  ' "$_EPICS"
}

# Collect into parallel arrays (POSIX-portable: macOS bash 3.2 has no
# associative arrays so we keep it indexed).
_KEYS=()
_TITLES=()
_RISKS=()

while IFS=$'\t' read -r _k _t _r; do
  [ -n "$_k" ] || continue
  _KEYS+=("$_k")
  _TITLES+=("$_t")
  _RISKS+=("$_r")
done < <(_parse_high_risk)

_count="${#_KEYS[@]}"

# ---------- Graceful empty-list exit (AC5 / VCP-ATDD-05) ----------

if [ "$_count" -eq 0 ]; then
  printf 'No high-risk stories found — nothing to generate\n'
  exit 0
fi

# ---------- Resolve --select indices (AC3 / VCP-ATDD-03, AC-EC6) ----------

_SELECTED_INDICES=()
if [ -n "$_SELECT" ]; then
  IFS=',' read -ra _raw <<< "$_SELECT"
  for _entry in "${_raw[@]}"; do
    # Trim whitespace
    _entry="${_entry#"${_entry%%[![:space:]]*}"}"
    _entry="${_entry%"${_entry##*[![:space:]]}"}"
    # Numeric?
    if ! [[ "$_entry" =~ ^[0-9]+$ ]]; then
      printf 'Invalid selection: %s (non-numeric)\n' "$_entry"
      exit 1
    fi
    # In range? (1-based)
    if [ "$_entry" -lt 1 ] || [ "$_entry" -gt "$_count" ]; then
      printf 'Invalid selection: %s (out of range 1..%d)\n' "$_entry" "$_count"
      exit 1
    fi
    _SELECTED_INDICES+=("$_entry")
  done
fi

# ---------- Emit output ----------

case "$_FORMAT" in
  keys)
    if [ "${#_SELECTED_INDICES[@]}" -gt 0 ]; then
      for _idx in "${_SELECTED_INDICES[@]}"; do
        printf '%s\n' "${_KEYS[$((_idx - 1))]}"
      done
    else
      for _k in "${_KEYS[@]}"; do
        printf '%s\n' "$_k"
      done
    fi
    ;;
  menu)
    printf 'High-risk stories discovered (%d):\n\n' "$_count"
    _i=1
    while [ "$_i" -le "$_count" ]; do
      printf '  %d. %s — %s [risk: %s]\n' \
        "$_i" "${_KEYS[$((_i - 1))]}" "${_TITLES[$((_i - 1))]}" "${_RISKS[$((_i - 1))]}"
      _i=$((_i + 1))
    done
    printf '\n'
    # AC-EC7: collapse to [all / skip] for a single story (no select).
    if [ "$_count" -eq 1 ]; then
      printf 'Choose: [all / skip]\n'
    else
      printf 'Choose: [all / select / skip]\n'
    fi
    ;;
  *)
    _die "unknown --format value: $_FORMAT (expected keys or menu)"
    ;;
esac

exit 0
