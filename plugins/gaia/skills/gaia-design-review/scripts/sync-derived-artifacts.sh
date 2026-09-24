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
#
# Exit codes:
#   0  — sync completed (additions and/or no-ops)
#   1  — argument error or file not found

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

# _add_component_to_doc COMPONENT DOC — insert a component line into
# the Component Inventory section of the doc.
_add_component_to_doc() {
  local component="$1" doc="$2"
  local tmpfile
  tmpfile="$(mktemp)"
  awk -v comp="$component" '
    /^## Component Inventory/ { in_section=1; print; next }
    in_section && /^##/ {
      printf "- %s\n", comp
      in_section=0
      print
      next
    }
    { print }
    END { if (in_section) printf "- %s\n", comp }
  ' "$doc" > "$tmpfile"
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

  local snapshot_components
  snapshot_components="$(jq -r '.components[]' "$snapshot_file" 2>/dev/null)" || \
    _die "failed to parse components from snapshot: $snapshot_file"

  local doc_components
  doc_components="$(_extract_doc_components "$ux_doc")"

  local added=0 component
  while IFS= read -r component; do
    [ -n "$component" ] || continue
    if ! printf '%s\n' "$doc_components" | grep -qxF "$component"; then
      _add_component_to_doc "$component" "$ux_doc"
      printf 'sync: added component "%s" to ux-design.md\n' "$component"
      added=$((added + 1))
      # Re-read after modification
      doc_components="$(_extract_doc_components "$ux_doc")"
    fi
  done <<< "$snapshot_components"

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
