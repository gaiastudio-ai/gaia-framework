#!/usr/bin/env bash
# list-adapters.sh — backs the /gaia-list-tools query skill.
#
# Story: E70-S5  (FR-RSV2-21, FR-RSV2-10, NFR-RSV2-4)
# Decisions: ADR-078 (Tool Adapter Framework), ADR-042 (Scripts-over-LLM).
#
# Purpose
#   Enumerate every tool adapter discoverable under the built-in and
#   project-local adapter roots, group rows by `category` (the canonical
#   adapter.json field), and emit a deterministic table. Each row carries
#   name, version-range, provider, runtime-profile, an availability slot,
#   and a precedence badge:
#       [custom]    — adapter resolved from CUSTOM_ADAPTERS_DIR
#       [shadowed]  — built-in adapter shadowed by a same-named custom one
#       (none)      — built-in adapter, not shadowed
#
# The script is read-only — it never writes to either adapter root.
#
# Environment
#   BUILTIN_ADAPTERS_DIR     Override the built-in adapter root (default:
#                            <plugin>/scripts/adapters).
#   CUSTOM_ADAPTERS_DIR      Override the project-local adapter root
#                            (default: <project-root>/custom/adapters).
#   GAIA_LIST_TOOLS_SKIP_PROBE
#                            When set to "1", skip the availability probe
#                            and emit "unknown" in the availability slot.
#                            Used by the bats fixtures so tests do not
#                            depend on the host PATH.
#
# Exit codes
#   0  — enumeration succeeded (an empty result is also exit 0)
#   1  — caller error (e.g. unreadable adapter root)
# =============================================================================

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="list-adapters.sh"
warn() { printf '%s: %s\n' "$prog" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILTIN_ROOT="${BUILTIN_ADAPTERS_DIR:-$PLUGIN_DIR/scripts/adapters}"
# Default custom root: project-root is two levels above the plugin dir
# (gaia-public/plugins/gaia → gaia-public). For native installs this resolves
# correctly; consumers override via CUSTOM_ADAPTERS_DIR when needed.
DEFAULT_CUSTOM_ROOT="$(cd "$PLUGIN_DIR/../.." 2>/dev/null && pwd)/custom/adapters"
CUSTOM_ROOT="${CUSTOM_ADAPTERS_DIR:-$DEFAULT_CUSTOM_ROOT}"

if ! command -v jq >/dev/null 2>&1; then
  warn "jq is required but not found in PATH"
  exit 1
fi

# Discover adapter directories under <root>. An adapter is any direct child
# directory whose name does not begin with '_' (the meta-directories
# `_schema/` and helpers like `_contract-helper.bash` are skipped).
_discover_adapters() {
  local root="$1"
  [ -d "$root" ] || return 0
  local d
  for d in "$root"/*; do
    [ -d "$d" ] || continue
    local base; base="$(basename "$d")"
    case "$base" in
      _*) continue ;;
    esac
    [ -f "$d/adapter.json" ] || continue
    printf '%s\n' "$base"
  done
}

# _read_field <adapter-dir> <field> — extract a top-level field from
# adapter.json. Empty string when missing or malformed.
_read_field() {
  local d="$1" f="$2"
  jq -r --arg f "$f" '.[$f] // ""' "$d/adapter.json" 2>/dev/null || printf ''
}

_probe_availability() {
  local adapter_dir="$1"
  if [ "${GAIA_LIST_TOOLS_SKIP_PROBE:-0}" = "1" ]; then
    printf 'unknown'
    return
  fi
  local probe="$PLUGIN_DIR/scripts/tool-availability-probe.sh"
  if [ ! -x "$probe" ]; then
    printf 'unknown'
    return
  fi
  # Empty file-list invokes the not_applicable / project-scope path on
  # adapters that need files. Acceptable for a quick at-listing slot;
  # consumers run the full probe via review-skill workflows.
  local empty_list; empty_list="$(mktemp)"
  : > "$empty_list"
  local out
  out="$("$probe" --adapter-dir "$adapter_dir" --file-list "$empty_list" --timeout 1 2>/dev/null || true)"
  rm -f "$empty_list"
  local state
  state="$(printf '%s' "$out" | jq -r '.state // "unknown"' 2>/dev/null || printf 'unknown')"
  case "$state" in
    available)            printf 'available' ;;
    expected_and_missing) printf 'unavailable' ;;
    ran_and_errored)      printf 'degraded' ;;
    not_applicable)       printf 'available' ;;
    *)                    printf 'unknown' ;;
  esac
}

# Build a tab-delimited row table in memory:
#   category \t name \t version \t provider \t runtime-profile \t availability \t badge
ROWS=()

# Collect built-in adapters first so we know which names a custom adapter shadows.
declare -a BUILTIN_NAMES=()
declare -a CUSTOM_NAMES=()

while IFS= read -r name; do
  [ -n "$name" ] || continue
  BUILTIN_NAMES+=("$name")
done < <(_discover_adapters "$BUILTIN_ROOT")

while IFS= read -r name; do
  [ -n "$name" ] || continue
  CUSTOM_NAMES+=("$name")
done < <(_discover_adapters "$CUSTOM_ROOT")

_is_in() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

# Custom rows
for name in "${CUSTOM_NAMES[@]:-}"; do
  [ -n "$name" ] || continue
  d="$CUSTOM_ROOT/$name"
  if ! jq -e . "$d/adapter.json" >/dev/null 2>&1; then
    warn "skipping malformed adapter.json under custom/: $name"
    continue
  fi
  cat="$(_read_field "$d" category)"
  ver="$(_read_field "$d" version-range)"
  prov="$(_read_field "$d" provider)"
  rp="$(_read_field "$d" runtime-profile)"
  avail="$(_probe_availability "$d")"
  ROWS+=("${cat:-uncategorized}	$name	$ver	$prov	$rp	$avail	[custom]")
done

# Built-in rows (mark shadowed if a same-named custom exists)
for name in "${BUILTIN_NAMES[@]:-}"; do
  [ -n "$name" ] || continue
  d="$BUILTIN_ROOT/$name"
  if ! jq -e . "$d/adapter.json" >/dev/null 2>&1; then
    warn "skipping malformed adapter.json under built-in: $name"
    continue
  fi
  cat="$(_read_field "$d" category)"
  ver="$(_read_field "$d" version-range)"
  prov="$(_read_field "$d" provider)"
  rp="$(_read_field "$d" runtime-profile)"
  avail="$(_probe_availability "$d")"
  badge=""
  if _is_in "$name" "${CUSTOM_NAMES[@]:-}"; then
    badge="[shadowed]"
  fi
  ROWS+=("${cat:-uncategorized}	$name	$ver	$prov	$rp	$avail	$badge")
done

if [ "${#ROWS[@]}" -eq 0 ]; then
  printf 'No adapters found.\n'
  printf '  Searched: %s\n' "$BUILTIN_ROOT"
  printf '            %s\n' "$CUSTOM_ROOT"
  printf '  Add adapters under either root and re-run /gaia-list-tools.\n'
  exit 0
fi

# Sort: by category (col 1), then by name (col 2). LC_ALL=C above pins this.
sorted="$(printf '%s\n' "${ROWS[@]}" | sort -t$'\t' -k1,1 -k2,2)"

printf 'Adapter                Version          Provider              Runtime       Availability   Badge\n'
printf '====================================================================================================\n'

current_cat=""
while IFS=$'\t' read -r cat name ver prov rp avail badge; do
  if [ "$cat" != "$current_cat" ]; then
    printf '\n[category: %s]\n' "$cat"
    current_cat="$cat"
  fi
  printf '  %-22s %-16s %-21s %-13s %-14s %s\n' \
    "$name" "$ver" "$prov" "$rp" "$avail" "$badge"
done <<<"$sorted"

exit 0
