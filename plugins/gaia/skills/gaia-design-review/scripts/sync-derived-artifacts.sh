#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# sync-derived-artifacts.sh — reconcile project-side designer changes
# into the derived ux-design.md.
#
# Usage: sync-derived-artifacts.sh <snapshot-file> <ux-design-doc-path>
#   - snapshot-file:      JSON listing components from the project
#   - ux-design-doc-path: the derived ux-design.md to update
#
# Contract:
#   - Adds components present in the snapshot but missing from the doc
#   - Never silently deletes: a removed component is reported, not dropped
#   - Values go in via jq --arg (no shell expansion in jq/yq)
#   - Component names containing control characters (newline, CR, etc.)
#     are rejected with no partial write to the doc
#   - All additions are batched into a single rewrite (one awk pass)
#
# Exit codes:
#   0  — sync completed (additions and/or no-ops)
#   1  — argument error, file not found, or invalid component name

_die() { printf 'sync-derived-artifacts.sh: %s\n' "$1" >&2; exit 1; }

# _extract_doc_components DOC — parse component names from the
# "## Component Inventory" section of a markdown file.
_extract_doc_components() {
  local doc="$1"
  local in_section=false
  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+Component[[:space:]]+Inventory ]]; then
      in_section=true
      continue
    fi
    if [ "$in_section" = true ] && [[ "$line" =~ ^## ]]; then
      break
    fi
    if [ "$in_section" = true ] && [[ "$line" =~ ^-[[:space:]] ]]; then
      printf '%s\n' "${line#- }"
    fi
  done < "$doc"
}

# _batch_add_components DOC COMPONENTS_FILE — insert all component
# lines from COMPONENTS_FILE (one per line) into the Component
# Inventory section of the doc in a single awk pass.
_batch_add_components() {
  local doc="$1" components_file="$2"
  local tmpfile
  tmpfile="$(mktemp)"

  awk '
    BEGIN {
      while ((getline comp < ARGV[2]) > 0) {
        comps[++n] = comp
      }
      delete ARGV[2]
    }
    /^## Component Inventory/ { in_section=1; print; next }
    in_section && /^##/ {
      for (i = 1; i <= n; i++) printf "- %s\n", comps[i]
      in_section=0
      print
      next
    }
    { print }
    END { if (in_section) for (i = 1; i <= n; i++) printf "- %s\n", comps[i] }
  ' "$doc" "$components_file" > "$tmpfile"
  mv -f "$tmpfile" "$doc"
}

# _main — entry point.
_main() {
  [ $# -ge 2 ] || _die "usage: sync-derived-artifacts.sh <snapshot-file> <ux-design-doc-path>"

  local snapshot_file="$1"
  local ux_doc="$2"

  [ -f "$snapshot_file" ] || _die "snapshot file not found: $snapshot_file"
  [ -f "$ux_doc" ]        || _die "ux-design doc not found: $ux_doc"

  command -v jq >/dev/null 2>&1 || _die "jq is required but not found on PATH"

  # Validate all component names before any processing — reject on first
  # control-character violation so the doc stays byte-identical.
  # Use jq to check for control characters within JSON string values
  # (POSIX [:cntrl:] class) before decoding with -r.
  local bad_name
  bad_name="$(jq -r '.components[] | select(test("[[:cntrl:]]"))' "$snapshot_file" 2>/dev/null | head -1)" || true
  if [ -n "$bad_name" ]; then
    printf 'sync-derived-artifacts.sh: invalid component name (contains control characters): %q\n' "$bad_name" >&2
    exit 1
  fi

  local snapshot_components
  snapshot_components="$(jq -r '.components[]' "$snapshot_file" 2>/dev/null)" || \
    _die "failed to parse components from snapshot: $snapshot_file"

  local doc_components
  doc_components="$(_extract_doc_components "$ux_doc")"

  # Collect all components to add in a temp file for a single-pass batch
  local additions_file
  additions_file="$(mktemp)"
  local added=0

  while IFS= read -r component; do
    [ -n "$component" ] || continue
    if ! printf '%s\n' "$doc_components" | grep -qxF "$component"; then
      printf '%s\n' "$component" >> "$additions_file"
      printf 'sync: added component "%s" to ux-design.md\n' "$component"
      added=$((added + 1))
    fi
  done <<< "$snapshot_components"

  # Apply all additions in a single rewrite
  if [ "$added" -gt 0 ]; then
    _batch_add_components "$ux_doc" "$additions_file"
  fi
  rm -f "$additions_file"

  # Report components in the doc but removed from the snapshot
  while IFS= read -r component; do
    [ -n "$component" ] || continue
    if ! printf '%s\n' "$snapshot_components" | grep -qxF "$component"; then
      printf 'sync: component "%s" is in ux-design.md but absent from the project snapshot (not removed — reporting only)\n' "$component"
    fi
  done <<< "$doc_components"

  if [ "$added" -eq 0 ]; then
    printf 'sync: ux-design.md is up to date — no components to add\n'
  fi
}

_main "$@"
