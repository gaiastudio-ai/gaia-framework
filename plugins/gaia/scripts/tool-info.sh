#!/usr/bin/env bash
# tool-info.sh — backs the /gaia-tool-info <name> query skill.
#
# Story: E70-S5  (FR-RSV2-21, FR-RSV2-10, NFR-RSV2-4)
# Decisions: ADR-078 (Tool Adapter Framework), ADR-042 (Scripts-over-LLM).
#
# Purpose
#   Render the full adapter.json metadata for one named adapter plus the
#   current three-state availability slot. Resolves the adapter using the
#   same precedence as list-adapters.sh: project-local (CUSTOM_ADAPTERS_DIR)
#   wins over built-in (BUILTIN_ADAPTERS_DIR).
#
#   Unknown adapter names exit non-zero and emit an actionable error
#   listing every available adapter so the caller can self-correct.
#
# Usage
#   tool-info.sh <adapter-name>
#
# Environment
#   BUILTIN_ADAPTERS_DIR / CUSTOM_ADAPTERS_DIR — same as list-adapters.sh.
#   GAIA_TOOL_INFO_SKIP_PROBE=1 — skip the availability probe and emit
#       "unknown" in the availability slot.
#
# Exit codes
#   0 — adapter resolved and rendered
#   1 — caller error (missing arg, jq missing, unreadable adapter.json)
#   2 — unknown adapter name
# =============================================================================

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="tool-info.sh"
warn() { printf '%s: %s\n' "$prog" "$*" >&2; }

if [ "$#" -lt 1 ]; then
  warn "usage: $prog <adapter-name>"
  exit 1
fi

ADAPTER_NAME="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILTIN_ROOT="${BUILTIN_ADAPTERS_DIR:-$PLUGIN_DIR/scripts/adapters}"
# E96-S3 / ADR-111 (supersedes ADR-020): prefer .gaia/custom/adapters/ over
# the legacy <project-root>/custom/adapters/. Legacy fallback retained during
# the 1-sprint transition window (removed in E96-S5).
_PROJECT_ROOT_HERE="$(cd "$PLUGIN_DIR/../.." 2>/dev/null && pwd)"
if [ -d "$_PROJECT_ROOT_HERE/.gaia/custom/adapters" ]; then
  DEFAULT_CUSTOM_ROOT="$_PROJECT_ROOT_HERE/.gaia/custom/adapters"
else
  DEFAULT_CUSTOM_ROOT="$_PROJECT_ROOT_HERE/custom/adapters"
fi
CUSTOM_ROOT="${CUSTOM_ADAPTERS_DIR:-$DEFAULT_CUSTOM_ROOT}"

if ! command -v jq >/dev/null 2>&1; then
  warn "jq is required but not found in PATH"
  exit 1
fi

# _list_available_names — print every adapter name discoverable under the
# two roots, deduplicated, sorted, one per line.
_list_available_names() {
  {
    if [ -d "$CUSTOM_ROOT" ]; then
      for d in "$CUSTOM_ROOT"/*; do
        [ -d "$d" ] || continue
        n="$(basename "$d")"
        case "$n" in _*) continue ;; esac
        [ -f "$d/adapter.json" ] || continue
        printf '%s\n' "$n"
      done
    fi
    if [ -d "$BUILTIN_ROOT" ]; then
      for d in "$BUILTIN_ROOT"/*; do
        [ -d "$d" ] || continue
        n="$(basename "$d")"
        case "$n" in _*) continue ;; esac
        [ -f "$d/adapter.json" ] || continue
        printf '%s\n' "$n"
      done
    fi
  } | sort -u
}

# Resolve adapter dir: custom first, then built-in.
ADAPTER_DIR=""
SOURCE_LABEL=""
if [ -f "$CUSTOM_ROOT/$ADAPTER_NAME/adapter.json" ]; then
  ADAPTER_DIR="$CUSTOM_ROOT/$ADAPTER_NAME"
  SOURCE_LABEL="custom"
elif [ -f "$BUILTIN_ROOT/$ADAPTER_NAME/adapter.json" ]; then
  ADAPTER_DIR="$BUILTIN_ROOT/$ADAPTER_NAME"
  SOURCE_LABEL="built-in"
fi

if [ -z "$ADAPTER_DIR" ]; then
  warn "unknown adapter: $ADAPTER_NAME"
  printf '%s: unknown adapter: %s\n' "$prog" "$ADAPTER_NAME"
  printf 'Available adapters:\n'
  available="$(_list_available_names)"
  if [ -z "$available" ]; then
    printf '  (none — built-in root: %s, custom root: %s)\n' "$BUILTIN_ROOT" "$CUSTOM_ROOT"
  else
    printf '%s\n' "$available" | sed 's/^/  /'
  fi
  exit 2
fi

if ! jq -e . "$ADAPTER_DIR/adapter.json" >/dev/null 2>&1; then
  warn "malformed adapter.json under $ADAPTER_DIR"
  exit 1
fi

# Render metadata. Use jq to print every top-level key/value pair so any
# optional fields (scope, plugin, file-extensions, etc.) appear without
# needing to enumerate them here.
printf '# Adapter: %s\n' "$ADAPTER_NAME"
printf 'source: %s (%s)\n' "$SOURCE_LABEL" "$ADAPTER_DIR"
printf '\n## adapter.json\n'
jq -r 'to_entries[] | "\(.key): \(.value | @json)"' "$ADAPTER_DIR/adapter.json"

# Availability slot
if [ "${GAIA_TOOL_INFO_SKIP_PROBE:-0}" = "1" ]; then
  printf '\n## availability: unknown (probe skipped)\n'
else
  probe="$PLUGIN_DIR/scripts/tool-availability-probe.sh"
  if [ ! -x "$probe" ]; then
    printf '\n## availability: unknown (probe script not executable)\n'
  else
    empty_list="$(mktemp)"; : > "$empty_list"
    out="$("$probe" --adapter-dir "$ADAPTER_DIR" --file-list "$empty_list" --timeout 2 2>&1 || true)"
    rm -f "$empty_list"
    state="$(printf '%s' "$out" | jq -r '.state // "unknown"' 2>/dev/null || printf 'unknown')"
    reason="$(printf '%s' "$out" | jq -r '.skip_reason // .error_detail // ""' 2>/dev/null || printf '')"
    printf '\n## availability: %s\n' "$state"
    [ -n "$reason" ] && printf 'reason: %s\n' "$reason"
  fi
fi

exit 0
