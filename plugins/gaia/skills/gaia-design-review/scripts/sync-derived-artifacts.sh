#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# sync-derived-artifacts.sh — reconcile project-side designer changes
# into the derived ux-design.md.
#
# Usage: sync-derived-artifacts.sh [--last-published <path>] <snapshot-file> <ux-design-doc-path>
#   - --last-published:   path to the persisted publication manifest
#                         (default: ${PROJECT_ROOT}/.gaia/state/design-last-published.json)
#   - snapshot-file:      JSON listing components and screens from the project
#   - ux-design-doc-path: the derived ux-design.md to update
#
# Contract:
#   - Adds components present in the snapshot but missing from the doc
#   - Reports screen changes with content in boundary markers (no doc write)
#   - Never silently deletes: a removed component is reported, not dropped
#   - Values go in via jq --arg (no shell expansion in jq/yq)
#   - Component and screen names containing control characters (newline, CR,
#     etc.) are rejected with no partial write to the doc
#   - All additions are batched into a single rewrite (one awk pass)
#   - The "added" diagnostic is printed only when the file actually changes
#
# Exit codes:
#   0  — sync completed (additions, no-ops, or screen-only reports)
#   1  — argument error, file not found, invalid component/screen name,
#         or missing heading (when components present)

_die() { printf 'sync-derived-artifacts.sh: %s\n' "$1" >&2; exit 1; }

# File-scope temp directory — every temp file lives inside it. Cleaned
# up on any exit so no individual file can leak.
_sync_tmpdir=""
_cleanup_tmpdir() { [ -n "${_sync_tmpdir:-}" ] && rm -rf "$_sync_tmpdir"; true; }
trap _cleanup_tmpdir EXIT INT TERM

# _sha256_file FILE — portable sha256 of a file
_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# _sha256_bytes — portable sha256 of stdin bytes (no trailing newline added)
_sha256_bytes() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# _extract_doc_components DOC — parse component names from the components
# section of a markdown file. Accepts the template heading (both & and
# "and" variants, case-insensitive, with optional number prefix) and the
# legacy "## Component Inventory" heading.
_extract_doc_components() {
  local doc="$1"
  local in_section=false
  local saw_separator=false

  shopt -s nocasematch
  while IFS= read -r line; do
    # Check for heading match (template or legacy)
    if [[ "$line" =~ ^##[[:space:]]+([0-9]+\.[[:space:]]+)?[Cc]omponents[[:space:]]+(and|\&)[[:space:]]+[Dd]esign[[:space:]]+[Ss]ystem ]] ||
       [[ "$line" =~ ^##[[:space:]]+[Cc]omponent[[:space:]]+[Ii]nventory ]]; then
      if [ "$in_section" = false ]; then
        in_section=true
        saw_separator=false
        continue
      fi
      # Second heading match — stop (template wins)
      break
    fi
    if [ "$in_section" = true ] && [[ "$line" =~ ^## ]]; then
      break
    fi
    if [ "$in_section" = true ]; then
      # Check for table separator row: cells contain only -, :, spaces
      if [[ "$line" =~ ^\|[[:space:]]*[-:] ]] && [[ "$line" =~ ^[[:space:]]*\|[[:space:]]*[-:|[:space:]]*$ ]]; then
        # The previous pipe line was the header — discard it
        saw_separator=true
        continue
      fi

      # Table row
      if [[ "$line" =~ ^\| ]]; then
        if [ "$saw_separator" = false ]; then
          # Before any separator: skip this line (it is the header row)
          continue
        fi
        # After separator: this is a data row — extract first cell
        local first_cell
        first_cell="$(printf '%s' "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')"
        if [ -n "$first_cell" ]; then
          printf '%s\n' "$first_cell"
        fi
        continue
      fi

      # Bullet list entry
      if [[ "$line" =~ ^-[[:space:]] ]]; then
        printf '%s\n' "${line#- }"
      fi
    fi
  done < "$doc"
  shopt -u nocasematch
}

# _count_table_cols DOC — count the number of columns in the first table
# within the matched section. Returns 0 if no table found.
_count_table_cols() {
  local doc="$1"
  local in_section=false

  shopt -s nocasematch
  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+([0-9]+\.[[:space:]]+)?[Cc]omponents[[:space:]]+(and|\&)[[:space:]]+[Dd]esign[[:space:]]+[Ss]ystem ]] ||
       [[ "$line" =~ ^##[[:space:]]+[Cc]omponent[[:space:]]+[Ii]nventory ]]; then
      if [ "$in_section" = false ]; then
        in_section=true
        continue
      fi
      break
    fi
    if [ "$in_section" = true ] && [[ "$line" =~ ^## ]]; then
      break
    fi
    if [ "$in_section" = true ]; then
      # Separator row tells us column count
      if [[ "$line" =~ ^\|[[:space:]]*[-:] ]] && [[ "$line" =~ ^[[:space:]]*\|[[:space:]]*[-:|[:space:]]*$ ]]; then
        # Count pipes minus 1 (leading and trailing pipes)
        local pipe_count
        pipe_count="$(printf '%s' "$line" | awk '{n=gsub(/\|/,"|"); print n}')"
        shopt -u nocasematch
        printf '%d\n' "$((pipe_count - 1))"
        return 0
      fi
    fi
  done < "$doc"
  shopt -u nocasematch
  printf '0\n'
}

# _batch_add_components DOC COMPONENTS_FILE — insert all component
# lines from COMPONENTS_FILE (one per line) into the components section
# of the doc in a single awk pass. Supports both table and bullet formats.
_batch_add_components() {
  local doc="$1" components_file="$2"
  local tmpfile
  tmpfile="$_sync_tmpdir/awk-out"

  # Determine the insert format: table or bullet
  local col_count
  col_count="$(_count_table_cols "$doc")"

  if [ "$col_count" -gt 0 ]; then
    # Table mode: insert as table rows padded to col_count
    awk -v cols="$col_count" '
      BEGIN {
        while ((getline comp < ARGV[2]) > 0) {
          # Escape pipe characters in the component name
          gsub(/\|/, "\\|", comp)
          comps[++n] = comp
        }
        delete ARGV[2]
      }
      function heading_match(s,   low) {
        low = tolower(s)
        return (low ~ /^## +(([0-9]+\. +)?components +(and|&) +design +system|component +inventory)/)
      }
      in_section && /^##/ {
        for (i = 1; i <= n; i++) {
          row = "| " comps[i] " |"
          for (c = 2; c <= cols; c++) row = row " |"
          printf "%s\n", row
        }
        in_section=0
        done_section=1
        print
        next
      }
      !done_section && heading_match($0) { in_section=1; print; next }
      { print }
      END {
        if (in_section) {
          for (i = 1; i <= n; i++) {
            row = "| " comps[i] " |"
            for (c = 2; c <= cols; c++) row = row " |"
            printf "%s\n", row
          }
        }
      }
    ' "$doc" "$components_file" > "$tmpfile"
  else
    # Bullet mode
    awk '
      BEGIN {
        while ((getline comp < ARGV[2]) > 0) {
          comps[++n] = comp
        }
        delete ARGV[2]
      }
      function heading_match(s,   low) {
        low = tolower(s)
        return (low ~ /^## +(([0-9]+\. +)?components +(and|&) +design +system|component +inventory)/)
      }
      in_section && /^##/ {
        for (i = 1; i <= n; i++) printf "- %s\n", comps[i]
        in_section=0
        done_section=1
        print
        next
      }
      !done_section && heading_match($0) { in_section=1; print; next }
      { print }
      END { if (in_section) for (i = 1; i <= n; i++) printf "- %s\n", comps[i] }
    ' "$doc" "$components_file" > "$tmpfile"
  fi
  mv -f "$tmpfile" "$doc"
}

# _has_component_heading DOC — return 0 if the doc has a recognized heading
_has_component_heading() {
  local doc="$1"
  shopt -s nocasematch
  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+([0-9]+\.[[:space:]]+)?[Cc]omponents[[:space:]]+(and|\&)[[:space:]]+[Dd]esign[[:space:]]+[Ss]ystem ]] ||
       [[ "$line" =~ ^##[[:space:]]+[Cc]omponent[[:space:]]+[Ii]nventory ]]; then
      shopt -u nocasematch
      return 0
    fi
  done < "$doc"
  shopt -u nocasematch
  return 1
}

# _resolve_baseline — resolve the --last-published path
_resolve_baseline() {
  local explicit_path="${1:-}"
  if [ -n "$explicit_path" ]; then
    printf '%s\n' "$explicit_path"
    return
  fi
  # Try PROJECT_ROOT
  if [ -n "${PROJECT_ROOT:-}" ] && [ -f "${PROJECT_ROOT}/.gaia/state/design-last-published.json" ]; then
    printf '%s\n' "${PROJECT_ROOT}/.gaia/state/design-last-published.json"
    return
  fi
  # Walk up from PWD to find project-config anchor
  local dir
  dir="$(pwd)"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.gaia/config/project-config.yaml" ]; then
      if [ -f "$dir/.gaia/state/design-last-published.json" ]; then
        printf '%s\n' "$dir/.gaia/state/design-last-published.json"
        return
      fi
      break
    fi
    dir="$(dirname "$dir")"
  done
  # Not found — return empty
  printf ''
}

# _main — entry point.
_main() {
  # Parse named flags before positional args
  local last_published_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --last-published)
        [ $# -ge 2 ] || _die "usage: --last-published requires a path argument"
        last_published_arg="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        _die "unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  [ $# -ge 2 ] || _die "usage: sync-derived-artifacts.sh [--last-published <path>] <snapshot-file> <ux-design-doc-path>"

  local snapshot_file="$1"
  local ux_doc="$2"

  [ -f "$snapshot_file" ] || _die "snapshot file not found: $snapshot_file"
  [ -f "$ux_doc" ]        || _die "ux-design doc not found: $ux_doc"

  command -v jq >/dev/null 2>&1 || _die "jq is required but not found on PATH"

  # Create the session temp directory. All temp files live inside it so
  # the EXIT trap cleans up everything on any exit path.
  # _sync_tmpdir is file-scope (not local) so the trap can see it.
  _sync_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/sync-derived-artifacts.XXXXXX")"

  # === Snapshot shape validation ===
  # Validate top-level shape before any processing.
  local has_components=false
  local has_screens=false
  if jq -e '.components' "$snapshot_file" >/dev/null 2>&1; then
    # .components must be an array
    local comp_type
    comp_type="$(jq -r '.components | type' "$snapshot_file")"
    if [ "$comp_type" != "array" ]; then
      printf 'sync-derived-artifacts.sh: .components must be an array, got %s\n' "$comp_type" >&2
      exit 1
    fi
    # Every element must be a string
    local bad_elem
    bad_elem="$(jq -r '.components[] | select(type != "string") | type' "$snapshot_file" | head -1)" || true
    if [ -n "$bad_elem" ]; then
      printf 'sync-derived-artifacts.sh: .components[] elements must be strings, found %s\n' "$bad_elem" >&2
      exit 1
    fi
    has_components=true
  fi
  if jq -e '.screens' "$snapshot_file" >/dev/null 2>&1; then
    # .screens must be an array
    local screens_type
    screens_type="$(jq -r '.screens | type' "$snapshot_file")"
    if [ "$screens_type" != "array" ]; then
      printf 'sync-derived-artifacts.sh: .screens must be an array, got %s\n' "$screens_type" >&2
      exit 1
    fi
    has_screens=true
  fi

  # === Component sync ===
  local added=0
  if [ "$has_components" = true ]; then
    # Validate all component names before any processing — reject on first
    # control-character violation so the doc stays byte-identical.
    local bad_name
    bad_name="$(jq -r '.components[] | select(test("[[:cntrl:]]"))' "$snapshot_file" 2>/dev/null | head -1)" || true
    if [ -n "$bad_name" ]; then
      printf 'sync-derived-artifacts.sh: invalid component name (contains control characters): %q\n' "$bad_name" >&2
      exit 1
    fi

    local snapshot_components
    snapshot_components="$(jq -r '.components[]' "$snapshot_file" 2>/dev/null)" || \
      _die "failed to parse components from snapshot: $snapshot_file"

    # Check that the doc has a recognized heading (if there are components to sync)
    local component_count
    component_count="$(jq -r '.components | length' "$snapshot_file")"
    if [ "$component_count" -gt 0 ] && ! _has_component_heading "$ux_doc"; then
      printf 'sync-derived-artifacts.sh: no component section found — expected "## N. Components & Design System" or "## Component Inventory"\n' >&2
      exit 1
    fi

    local doc_components
    doc_components="$(_extract_doc_components "$ux_doc")"

    # Collect all components to add in a temp file for a single-pass batch
    local additions_file
    additions_file="$_sync_tmpdir/additions"

    while IFS= read -r component; do
      [ -n "$component" ] || continue
      if ! printf '%s\n' "$doc_components" | grep -qxF "$component"; then
        printf '%s\n' "$component" >> "$additions_file"
        added=$((added + 1))
      fi
    done <<< "$snapshot_components"

    # Apply all additions in a single rewrite, then verify the file changed
    if [ "$added" -gt 0 ]; then
      local sha_before
      sha_before="$(_sha256_file "$ux_doc")"

      _batch_add_components "$ux_doc" "$additions_file"

      local sha_after
      sha_after="$(_sha256_file "$ux_doc")"

      if [ "$sha_before" != "$sha_after" ]; then
        # File actually changed — print the diagnostics
        while IFS= read -r component; do
          [ -n "$component" ] || continue
          printf 'sync: added component "%s" to ux-design.md\n' "$component"
        done < "$additions_file"
      else
        # File unchanged despite additions — heading was not found by awk
        # (should not happen if _has_component_heading passed, but guard)
        printf 'sync-derived-artifacts.sh: no component section found — expected "## N. Components & Design System" or "## Component Inventory"\n' >&2
        rm -f "$additions_file"
        exit 1
      fi
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
  fi

  # === Screen reporting ===
  if [ "$has_screens" = true ]; then
    # --- Single-jq validation pass ---
    # One jq call validates all screens: field types, name control chars,
    # and content type. Emits "OK" or a single error line.
    local validation_result
    validation_result="$(jq -r '
      .screens | to_entries[] |
      if (.value.name | type) != "string" then
        "ERR\t.screens[\(.key)].name must be a string, got \(.value.name | type)"
      elif (.value.file | type) != "string" then
        "ERR\t.screens[\(.key)].file must be a string, got \(.value.file | type)"
      elif (.value.name | test("[[:cntrl:]]")) then
        "ERR_CTRL\t\(.value.name)"
      elif (.value.content | type) != "string" then
        "ERR_CONTENT\t\(.value.name)\t\(.value.content | type)\t\(.value.file)"
      else empty end
    ' "$snapshot_file" | head -1)" || true

    if [ -n "$validation_result" ]; then
      local err_kind
      err_kind="${validation_result%%	*}"
      case "$err_kind" in
        ERR)
          local err_msg="${validation_result#*	}"
          printf 'sync-derived-artifacts.sh: %s\n' "$err_msg" >&2
          exit 1
          ;;
        ERR_CTRL)
          local bad_name="${validation_result#*	}"
          printf 'sync-derived-artifacts.sh: invalid screen name (contains control characters): %q\n' "$bad_name" >&2
          exit 1
          ;;
        ERR_CONTENT)
          # Parse: ERR_CONTENT<tab>name<tab>type<tab>file
          local rest="${validation_result#*	}"
          local scr_name="${rest%%	*}"
          rest="${rest#*	}"
          local scr_type="${rest%%	*}"
          local scr_file="${rest#*	}"
          printf 'sync-derived-artifacts.sh: screen "%s" has invalid content (type: %s, expected string; file: %s)\n' \
            "$scr_name" "$scr_type" "$scr_file" >&2
          exit 1
          ;;
      esac
    fi

    # --- Resolve baseline and build index ---
    local baseline_path
    baseline_path="$(_resolve_baseline "$last_published_arg")"

    local baseline_index="$_sync_tmpdir/baseline-index"
    : > "$baseline_index"
    if [ -n "$baseline_path" ] && [ -f "$baseline_path" ]; then
      # Build tab-delimited index: file<TAB>hash — one jq call
      jq -r '.[] | "\(.file)\t\(.hash)"' "$baseline_path" > "$baseline_index"
    fi

    # --- Extract screen metadata in one jq call ---
    local screen_meta="$_sync_tmpdir/screen-meta"
    jq -r '.screens | to_entries[] | "\(.key)\t\(.value.name)\t\(.value.file)"' \
      "$snapshot_file" > "$screen_meta"

    # --- Extract all content files in two jq calls ---
    # 1. One jq call to get the byte-length of each screen's content.
    # 2. One jq call to concatenate all content (exact bytes via -j).
    # Then split the concatenated output by byte lengths.
    local content_dir="$_sync_tmpdir/contents"
    mkdir -p "$content_dir"

    # Get byte-lengths of each screen's content (one per line)
    local lengths_file="$_sync_tmpdir/content-lengths"
    jq -r '[.screens[].content | utf8bytelength] | .[]' "$snapshot_file" > "$lengths_file"

    # Concatenate all content into one stream and split by length.
    # jq -j outputs exact bytes without trailing newline.
    local concat_file="$_sync_tmpdir/content-all"
    jq -j '[.screens[].content] | join("")' "$snapshot_file" > "$concat_file"

    # Split the concatenated content into individual files by byte length.
    # Read from a file descriptor so each dd picks up where the last left off.
    local idx=0
    exec 3< "$concat_file"
    while IFS= read -r len; do
      if [ "$len" -gt 0 ]; then
        dd bs="$len" count=1 of="$content_dir/$idx" 2>/dev/null <&3
      else
        : > "$content_dir/$idx"
      fi
      idx=$((idx + 1))
    done < "$lengths_file"
    exec 3<&-

    # --- Hash and report pass ---
    # Content files are pre-extracted. Name and file are read from the
    # pre-extracted metadata. Baseline lookup uses the pre-built index.
    while IFS=$'\t' read -r idx screen_name screen_file; do
      local content_file="$content_dir/$idx"

      # Hash the exact file bytes (preserves trailing newlines)
      local content_hash
      content_hash="$(_sha256_file "$content_file")"

      # Look up the baseline hash from the pre-built index
      local baseline_hash=""
      if [ -s "$baseline_index" ]; then
        baseline_hash="$(LOOKUP_FILE="$screen_file" awk -F'\t' '$1 == ENVIRON["LOOKUP_FILE"] {print $2; exit}' "$baseline_index")" || true
      fi

      if [ -z "$baseline_hash" ]; then
        # No baseline entry — report as "no baseline"
        printf 'sync: screen "%s" has no baseline (file: %s)\n' "$screen_name" "$screen_file"
        printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n'
        cat "$content_file"
        # Ensure the closing marker is on its own line
        if [ -s "$content_file" ] && [ "$(tail -c 1 "$content_file" | wc -l)" -eq 0 ]; then
          printf '\n'
        fi
        printf '<<<END_DESIGN_PROJECT_BOUNDARY>>>\n'
      elif [ "$content_hash" != "$baseline_hash" ]; then
        # Content changed
        printf 'sync: screen "%s" changed (file: %s)\n' "$screen_name" "$screen_file"
        printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n'
        cat "$content_file"
        # Ensure the closing marker is on its own line
        if [ -s "$content_file" ] && [ "$(tail -c 1 "$content_file" | wc -l)" -eq 0 ]; then
          printf '\n'
        fi
        printf '<<<END_DESIGN_PROJECT_BOUNDARY>>>\n'
      fi
      # Unchanged screens: no report
    done < "$screen_meta"
  fi

  # If no components and no screens, just report up to date
  if [ "$has_components" = false ] && [ "$has_screens" = false ]; then
    printf 'sync: ux-design.md is up to date — no components to add\n'
  fi
}

_main "$@"
