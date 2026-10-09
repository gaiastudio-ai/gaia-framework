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

# ---- source shared libs -----------------------------------------------------
_SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SYNC_SAFE_FN="$(cd "$_SYNC_DIR" && cd ../../../scripts/lib && pwd)/safe-filename.sh"
[ -f "$_SYNC_SAFE_FN" ] || _die "missing shared lib: $_SYNC_SAFE_FN"
# shellcheck source=../../../scripts/lib/safe-filename.sh
. "$_SYNC_SAFE_FN"

_SYNC_ESCAPE="$(cd "$_SYNC_DIR" && cd ../../../scripts/lib && pwd)/escape-boundary-markers.sh"
[ -f "$_SYNC_ESCAPE" ] || _die "missing shared lib: $_SYNC_ESCAPE"
# shellcheck source=../../../scripts/lib/escape-boundary-markers.sh
. "$_SYNC_ESCAPE"

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

# _is_section_end LINE — true when the line is a level-1 or level-2
# heading (which closes the component section).  Level-3 and deeper
# headings (###, ####, ...) are subsection content and do NOT end it.
_is_section_end() {
  [[ "$1" == '# '* ]] || { [[ "$1" == '## '* ]] && ! [[ "$1" == '### '* ]]; }
}

# _extract_doc_components DOC — parse component names from the components
# section of a markdown file. Accepts: the template heading "## N. Components
# & Design System" (both & and "and" variants, case-insensitive, with optional
# number prefix), the bare "## N. Components" heading (number optional), and
# the legacy "## Component Inventory" heading.
_extract_doc_components() {
  local doc="$1"

  # Single awk pass: find the components section, detect separator
  # (piped or pipe-less), extract first cell from data rows using an
  # escape-aware splitter (index/substr on fixed characters only —
  # never uses a data value as a regex), unescape, and print.
  # Bullet-mode extraction runs when no table is found.
  awk '
    function heading_match(s,   low) {
      low = tolower(s)
      return (low ~ /^## +(([0-9]+\. +)?components +(and|&) +design +system|component +inventory|([0-9]+\. +)?components[[:space:]]*$)/)
    }
    function is_section_end(s) {
      return (s ~ /^# [^#]/ || s ~ /^# $/ || (s ~ /^## / && s !~ /^### /))
    }
    # is_separator LINE — true when the line is a table separator:
    # contains at least one | and three consecutive dashes, and consists
    # only of -, :, |, spaces, and optional trailing \r.
    function is_separator(s,   clean) {
      if (index(s, "|") == 0) return 0
      if (index(s, "---") == 0) return 0
      clean = s
      gsub(/\r$/, "", clean)
      gsub(/[-:|[:space:]]/, "", clean)
      return (clean == "")
    }
    # extract_first_cell LINE — escape-aware first-cell extraction.
    # Splits on unescaped | (preceded by even number of backslashes).
    # Returns unescaped first data cell (skipping the leading empty
    # cell when the row has a leading pipe).
    function extract_first_cell(line,   i, ch, cell, bs, cell_idx, target, has_lp, len, j, uch, out) {
      len = length(line)
      # Detect leading pipe (after optional whitespace)
      has_lp = 0
      for (i = 1; i <= len; i++) {
        ch = substr(line, i, 1)
        if (ch == " " || ch == "\t") continue
        if (ch == "|") has_lp = 1
        break
      }
      cell = ""
      bs = 0
      cell_idx = 0
      for (i = 1; i <= len; i++) {
        ch = substr(line, i, 1)
        if (ch == "\\") {
          cell = cell ch
          bs++
        } else if (ch == "|" && (bs % 2) == 0) {
          # Unescaped pipe — cell boundary
          if (has_lp && cell_idx == 0) {
            # Skip leading empty cell
          } else if ((has_lp && cell_idx == 1) || (!has_lp && cell_idx == 0)) {
            target = cell
            break
          }
          cell_idx++
          cell = ""
          bs = 0
        } else {
          cell = cell ch
          bs = 0
        }
      }
      # If we never hit a second boundary, use what we have
      if (target == "") {
        if (has_lp && cell_idx == 1) target = cell
        else if (!has_lp && cell_idx == 0) target = cell
      }
      # Trim whitespace (including \r)
      gsub(/^[[:space:]]+/, "", target)
      gsub(/[[:space:]]+$/, "", target)
      # Unescape: \\ -> \, \| -> | (process left to right with substr)
      out = ""
      j = 1
      len = length(target)
      while (j <= len) {
        uch = substr(target, j, 1)
        if (uch == "\\" && j < len) {
          nch = substr(target, j + 1, 1)
          if (nch == "\\") { out = out "\\"; j += 2; continue }
          if (nch == "|")  { out = out "|";  j += 2; continue }
        }
        out = out uch
        j++
      }
      return out
    }
    # is_data_row LINE — true when inside a table block and the line is
    # a data row: starts with | or contains a | (pipe-less form), but
    # is never a bullet.
    function is_data_row(s) {
      if (s ~ /^-[[:space:]]/) return 0
      if (index(s, "|") > 0) return 1
      return 0
    }

    !done_section && heading_match($0) {
      if (!in_section) { in_section = 1; next }
      else { done_section = 1; next }
    }
    in_section && is_section_end($0) { done_section = 1; next }
    in_section && !first_table_done {
      if (is_separator($0)) { saw_sep = 1; next }
      if (saw_sep && is_data_row($0)) {
        name = extract_first_cell($0)
        if (name != "") print name
        next
      }
      if (saw_sep) { first_table_done = 1 }
      # Bullet (only when no table found yet)
      if (!saw_sep && $0 ~ /^-[[:space:]]/) {
        name = substr($0, 3)
        # Strip trailing \r from CRLF docs
        gsub(/\r$/, "", name)
        print name
      }
    }
  ' "$doc"
}

# _count_table_cols DOC — count the number of columns in the first table
# within the matched section. Returns 0 if no table found.
_count_table_cols() {
  local doc="$1"
  local in_section=false

  shopt -s nocasematch
  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+([0-9]+\.[[:space:]]+)?[Cc]omponents[[:space:]]+(and|\&)[[:space:]]+[Dd]esign[[:space:]]+[Ss]ystem ]] ||
       [[ "$line" =~ ^##[[:space:]]+[Cc]omponent[[:space:]]+[Ii]nventory ]] ||
       [[ "$line" =~ ^##[[:space:]]+([0-9]+\.[[:space:]]+)?[Cc]omponents[[:space:]]*$ ]]; then
      if [ "$in_section" = false ]; then
        in_section=true
        continue
      fi
      break
    fi
    if [ "$in_section" = true ]; then
      # Section ends at level-1 or level-2 headings
      if _is_section_end "$line"; then break; fi

      # Separator row: must have at least one | and three consecutive
      # dashes, and consist only of -, :, |, spaces, and optional \r.
      # Accepts piped (|---|---|---) and pipe-less (---|---|---) forms.
      local clean="${line%$'\r'}"
      if [[ "$clean" == *'|'* ]] && [[ "$clean" == *'---'* ]]; then
        local stripped="${clean//[-:|[:space:]]/}"
        if [ -z "$stripped" ]; then
          # Count pipes
          local pipe_count
          pipe_count="$(printf '%s' "$line" | awk '{n=gsub(/\|/,"|"); print n}')"
          # Detect outer pipes: leading pipe = first non-space is |
          # trailing pipe = last non-space (ignoring \r) is |
          local has_leading=false has_trailing=false
          [[ "$clean" =~ ^[[:space:]]*\| ]] && has_leading=true
          [[ "$clean" =~ \|[[:space:]]*$ ]] && has_trailing=true
          local cols
          if [ "$has_leading" = true ] && [ "$has_trailing" = true ]; then
            cols=$((pipe_count - 1))
          elif [ "$has_leading" = true ] || [ "$has_trailing" = true ]; then
            cols=$pipe_count
          else
            cols=$((pipe_count + 1))
          fi
          shopt -u nocasematch
          printf '%d\n' "$cols"
          return 0
        fi
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

  # Detect document line-ending convention from the first line.
  # Pass as a 0/1 flag to awk (awk -v cannot carry embedded newlines).
  local _doc_crlf=0
  local _first_line
  _first_line="$(head -1 "$doc")"
  if [[ "$_first_line" == *$'\r' ]]; then
    _doc_crlf=1
  fi

  # Determine the insert format: table or bullet
  local col_count
  col_count="$(_count_table_cols "$doc")"

  if [ "$col_count" -gt 0 ]; then
    # Escape component names in bash for table mode:
    # \ -> \\, then | -> \|. Never done in awk gsub (portability).
    local escaped_file="$_sync_tmpdir/escaped-additions"
    local _v
    while IFS= read -r _v; do
      _v="${_v//\\/\\\\}"
      _v="${_v//|/\\|}"
      printf '%s\n' "$_v"
    done < "$components_file" > "$escaped_file"

    # Detect the table's pipe form from the separator line.
    # has_leading_pipe / has_trailing_pipe are passed to awk.
    local _sep_line _sep_clean _has_lp=0 _has_tp=0
    _sep_line="$(awk '
      function heading_match(s,   low) {
        low = tolower(s)
        return (low ~ /^## +(([0-9]+\. +)?components +(and|&) +design +system|component +inventory|([0-9]+\. +)?components[[:space:]]*$)/)
      }
      function is_section_end(s) {
        return (s ~ /^# [^#]/ || s ~ /^# $/ || (s ~ /^## / && s !~ /^### /))
      }
      !found && heading_match($0) { in_s = 1; next }
      in_s && is_section_end($0) { exit }
      in_s && /\|/ && /---/ {
        clean = $0; gsub(/\r$/, "", clean); gsub(/[-:|[:space:]]/, "", clean)
        if (clean == "") { print $0; found = 1; exit }
      }
    ' "$doc")"
    _sep_clean="${_sep_line%$'\r'}"
    [[ "$_sep_clean" =~ ^[[:space:]]*\| ]] && _has_lp=1
    [[ "$_sep_clean" =~ \|[[:space:]]*$ ]] && _has_tp=1

    # Table mode: insert new component rows immediately after the first
    # table's last pipe line, before any trailing blank lines, prose, or
    # headings.  A pending-line buffer tracks contiguous pipe blocks so
    # the insertion point is the end of the first table that contains a
    # separator row.
    awk -v cols="$col_count" -v crlf="$_doc_crlf" \
        -v has_lp="$_has_lp" -v has_tp="$_has_tp" '
      BEGIN {
        eol = (crlf ? "\r\n" : "\n")
        while ((getline comp < ARGV[2]) > 0) {
          comps[++n] = comp
        }
        delete ARGV[2]
      }
      function heading_match(s,   low) {
        low = tolower(s)
        return (low ~ /^## +(([0-9]+\. +)?components +(and|&) +design +system|component +inventory|([0-9]+\. +)?components[[:space:]]*$)/)
      }
      # Only level-1 and level-2 headings end the section; ### and deeper do not
      function is_section_end(s) {
        return (s ~ /^# [^#]/ || s ~ /^# $/ || (s ~ /^## / && s !~ /^### /))
      }
      # is_separator — pipe-less-aware separator check
      function is_sep(s,   clean) {
        if (index(s, "|") == 0) return 0
        if (index(s, "---") == 0) return 0
        clean = s; gsub(/\r$/, "", clean); gsub(/[-:|[:space:]]/, "", clean)
        return (clean == "")
      }
      # is_table_line — starts with | or contains | and is not a bullet
      function is_table_line(s) {
        if (s ~ /^-[[:space:]]/) return 0
        return (index(s, "|") > 0)
      }
      function flush_pending(    i2) {
        for (i2 = 1; i2 <= npend; i2++) printf "%s\n", pending[i2]
        npend = 0
      }
      function flush_comps(    i2, row, c2) {
        if (flushed) return
        for (i2 = 1; i2 <= n; i2++) {
          if (has_lp) {
            row = "| " comps[i2] " |"
          } else {
            row = comps[i2] " |"
          }
          for (c2 = 2; c2 <= cols; c2++) {
            if (c2 < cols || has_tp) row = row " |"
            else row = row " "
          }
          printf "%s%s", row, eol
        }
        flushed = 1
      }

      # Rule order is load-bearing: this section-end rule MUST precede
      # the buffer rule below.  Both end with next.  If section-end came
      # after the buffer rule, a heading line would be captured into the
      # pending buffer instead of triggering a flush.
      !done_section && in_section && is_section_end($0) {
        flush_pending()
        flush_comps()
        in_section = 0
        done_section = 1
        print
        next
      }

      !done_section && heading_match($0) { in_section = 1; print; next }

      # Buffer rule — must come AFTER section-end (see note above)
      in_section && !first_table_done {
        if (is_table_line($0)) {
          pending[++npend] = $0
          if (is_sep($0)) {
            saw_sep = 1
          }
          next
        } else {
          if (npend > 0) {
            flush_pending()
            if (saw_sep) {
              flush_comps()
              first_table_done = 1
            }
            saw_sep = 0
          }
          print
          next
        }
      }

      { print }

      END {
        flush_pending()
        if (in_section) flush_comps()
      }
    ' "$doc" "$escaped_file" > "$tmpfile"
  else
    # Bullet mode: insert new bullets at the section boundary.
    # No escaping — bullet mode writes raw names. CRLF-aware.
    awk -v crlf="$_doc_crlf" '
      BEGIN {
        eol = (crlf ? "\r\n" : "\n")
        while ((getline comp < ARGV[2]) > 0) {
          comps[++n] = comp
        }
        delete ARGV[2]
      }
      function heading_match(s,   low) {
        low = tolower(s)
        return (low ~ /^## +(([0-9]+\. +)?components +(and|&) +design +system|component +inventory|([0-9]+\. +)?components[[:space:]]*$)/)
      }
      # Only level-1 and level-2 headings end the section; ### and deeper do not
      function is_section_end(s) {
        return (s ~ /^# [^#]/ || s ~ /^# $/ || (s ~ /^## / && s !~ /^### /))
      }
      in_section && is_section_end($0) {
        for (i = 1; i <= n; i++) printf "- %s%s", comps[i], eol
        in_section=0
        done_section=1
        print
        next
      }
      !done_section && heading_match($0) { in_section=1; print; next }
      { print }
      END { if (in_section) for (i = 1; i <= n; i++) printf "- %s%s", comps[i], eol }
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
       [[ "$line" =~ ^##[[:space:]]+[Cc]omponent[[:space:]]+[Ii]nventory ]] ||
       [[ "$line" =~ ^##[[:space:]]+([0-9]+\.[[:space:]]+)?[Cc]omponents[[:space:]]*$ ]]; then
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

# _resolve_token_baseline — resolve the token baseline path.
# Unlike _resolve_baseline, returns the path EVEN WHEN THE FILE DOES NOT
# EXIST YET (the first sync creates it).
_resolve_token_baseline() {
  local explicit_path="${1:-}"
  if [ -n "$explicit_path" ]; then
    printf '%s\n' "$explicit_path"
    return
  fi
  # Try PROJECT_ROOT
  if [ -n "${PROJECT_ROOT:-}" ]; then
    printf '%s\n' "${PROJECT_ROOT}/.gaia/state/design-token-baseline.json"
    return
  fi
  # Walk up from PWD to find project-config anchor
  local dir
  dir="$(pwd)"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.gaia/config/project-config.yaml" ]; then
      printf '%s\n' "$dir/.gaia/state/design-token-baseline.json"
      return
    fi
    dir="$(dirname "$dir")"
  done
  # Not found — return empty (caller decides whether to warn or fail)
  printf ''
}

# _main — entry point.
_main() {
  # Parse named flags before positional args
  local last_published_arg="" _sync_project="design_system" _token_baseline_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --last-published)
        [ $# -ge 2 ] || _die "usage: --last-published requires a path argument"
        last_published_arg="$2"
        shift 2
        ;;
      --project)
        [ $# -ge 2 ] || _die "usage: --project requires a value argument"
        _sync_project="$2"
        shift 2
        ;;
      --token-baseline)
        [ $# -ge 2 ] || _die "usage: --token-baseline requires a path argument"
        _token_baseline_arg="$2"
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

  case "$_sync_project" in
    design_system|product_design) ;;
    *) _die "invalid --project value: $_sync_project (must be design_system or product_design)" ;;
  esac

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

  # === Snapshot shape projection ===
  # Support combined shape {design_system:{...}, product_design:{...}} and
  # legacy flat shape {components:[...], screens:[...]}.
  # Project the snapshot to a working file containing only what this --project
  # pass needs: .components/.templates/.tokens for design_system,
  # .screens/.flows for product_design.
  local _orig_snapshot_file="$snapshot_file"
  local _is_combined=false
  if jq -e '.design_system // .product_design' "$snapshot_file" >/dev/null 2>&1; then
    _is_combined=true
  fi

  local _projected="$_sync_tmpdir/projected.json"
  if [ "$_is_combined" = true ]; then
    # Combined shape — validate part types before projecting.
    if [ "$_sync_project" = "design_system" ]; then
      # The design_system part must be an object (or absent/null).
      local _ds_type
      _ds_type="$(jq -r '.design_system | type' "$snapshot_file" 2>/dev/null)" || _ds_type="unknown"
      if [ "$_ds_type" != "object" ] && [ "$_ds_type" != "null" ]; then
        printf 'sync-derived-artifacts.sh: combined snapshot design_system must be an object, got %s\n' "$_ds_type" >&2
        exit 1
      fi
      # Validate components and templates are arrays when present
      local _ds_part_err
      _ds_part_err="$(jq -r '
        (.design_system // {}) |
        if (.components // null) != null and (.components | type) != "array" then
          ".components must be an array, got \(.components | type)"
        elif (.templates // null) != null and (.templates | type) != "array" then
          ".templates must be an array, got \(.templates | type)"
        else empty end
      ' "$snapshot_file" 2>/dev/null | head -1)" || true
      if [ -n "$_ds_part_err" ]; then
        printf 'sync-derived-artifacts.sh: combined snapshot design_system%s\n' "$_ds_part_err" >&2
        exit 1
      fi
      # Merge templates into components for the design_system pass
      jq '
        (.design_system // {}) |
        {components: ((.components // []) + (.templates // []) | unique),
         screens: [], tokens: (.tokens // {})}
      ' "$snapshot_file" > "$_projected"
    else
      # The product_design part must be an object (or absent/null).
      local _pd_part_type
      _pd_part_type="$(jq -r '.product_design | type' "$snapshot_file" 2>/dev/null)" || _pd_part_type="unknown"
      if [ "$_pd_part_type" != "object" ] && [ "$_pd_part_type" != "null" ]; then
        printf 'sync-derived-artifacts.sh: combined snapshot product_design must be an object, got %s\n' "$_pd_part_type" >&2
        exit 1
      fi
      # product_design pass — extract screens and flows
      jq '
        (.product_design // {}) |
        {components: [], screens: (.screens // []),
         flows: (.flows // [])}
      ' "$snapshot_file" > "$_projected"
    fi
    snapshot_file="$_projected"
  else
    # Legacy flat shape — map components to design_system, screens to product_design
    if [ "$_sync_project" = "design_system" ]; then
      jq '{components: (.components // []), screens: []}' "$snapshot_file" > "$_projected"
    else
      jq '{components: [], screens: (.screens // [])}' "$snapshot_file" > "$_projected"
    fi
    snapshot_file="$_projected"
  fi

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
    # Only flag components as present when the array is non-empty
    local comp_len
    comp_len="$(jq '.components | length' "$snapshot_file")"
    if [ "$comp_len" -gt 0 ]; then
      has_components=true
    fi
  fi
  if jq -e '.screens' "$snapshot_file" >/dev/null 2>&1; then
    # .screens must be an array
    local screens_type
    screens_type="$(jq -r '.screens | type' "$snapshot_file")"
    if [ "$screens_type" != "array" ]; then
      printf 'sync-derived-artifacts.sh: .screens must be an array, got %s\n' "$screens_type" >&2
      exit 1
    fi
    local scr_len
    scr_len="$(jq '.screens | length' "$snapshot_file")"
    if [ "$scr_len" -gt 0 ]; then
      has_screens=true
    fi
  fi

  # Check for flows (product_design pass only)
  local has_flows=false
  if jq -e '.flows' "$snapshot_file" >/dev/null 2>&1; then
    local flows_type
    flows_type="$(jq -r '.flows | type' "$snapshot_file")"
    if [ "$flows_type" != "array" ]; then
      printf 'sync-derived-artifacts.sh: .flows must be an array, got %s\n' "$flows_type" >&2
      exit 1
    fi
    has_flows=true
  fi

  # === Baseline validation (always, even with no screens) ===
  # Validates the publication baseline for hostile entries regardless of
  # whether this pass will process screens.
  local baseline_path
  baseline_path="$(_resolve_baseline "$last_published_arg")"
  if [ -n "$baseline_path" ] && [ -f "$baseline_path" ]; then
    local _bl_jq_prog
    _bl_jq_prog="
      ${SAFE_FILENAME_JQ_DEF}
      ${SAFE_HASH_JQ_DEF}
      if type == \"array\" then
        {\"design_system\": {\"files\": .}, \"product_design\": {\"files\": []}}
      else . end
      | .[\$proj].files // []
      | .[] | (.file | safe_filename) as \$f | (.hash | safe_hash) as \$h
      | \"\(\$f)\t\(\$h)\"
    "
    local _bl_validation_rc=0
    jq -r --arg proj "$_sync_project" "$_bl_jq_prog" \
      "$baseline_path" > /dev/null 2>&1 || _bl_validation_rc=$?
    if [ "$_bl_validation_rc" -ne 0 ]; then
      # Re-run to get the diagnostic on stderr
      jq -r --arg proj "$_sync_project" "$_bl_jq_prog" \
        "$baseline_path" >&2 2>&1 || true
      _die "unsafe or malformed baseline: $baseline_path"
    fi
  fi

  # === Component sync ===
  local added=0
  local snapshot_components=""
  local doc_components=""
  local _doc_components_extracted=false
  if [ "$has_components" = true ]; then
    # Validate all component names before any processing — reject on first
    # control-character violation so the doc stays byte-identical.
    local bad_name
    bad_name="$(jq -r '.components[] | select(test("[[:cntrl:]]"))' "$snapshot_file" 2>/dev/null | head -1)" || true
    if [ -n "$bad_name" ]; then
      printf 'sync-derived-artifacts.sh: invalid component name (contains control characters): %q\n' "$bad_name" >&2
      exit 1
    fi

    snapshot_components="$(jq -r '.components[]' "$snapshot_file" 2>/dev/null)" || \
      _die "failed to parse components from snapshot: $snapshot_file"

    # Check that the doc has a recognized heading (if there are components to sync)
    local component_count
    component_count="$(jq -r '.components | length' "$snapshot_file")"
    if [ "$component_count" -gt 0 ] && ! _has_component_heading "$ux_doc"; then
      printf 'sync-derived-artifacts.sh: no component section found — expected "## N. Components & Design System", "## N. Components", or "## Component Inventory"\n' >&2
      exit 1
    fi

    # Deduplicate snapshot component names, keeping first-seen order
    local deduped_components
    deduped_components="$(printf '%s\n' "$snapshot_components" | awk '!seen[$0]++')"
    snapshot_components="$deduped_components"

    doc_components="$(_extract_doc_components "$ux_doc")"
    _doc_components_extracted=true

    # Collect all components to add in a temp file for a single-pass batch.
    # Uses a single awk pass (set lookup) instead of per-component grep.
    local additions_file
    additions_file="$_sync_tmpdir/additions"

    local _doc_comp_file="$_sync_tmpdir/doc-components"
    printf '%s\n' "$doc_components" > "$_doc_comp_file"

    local _snap_comp_file="$_sync_tmpdir/snap-components"
    printf '%s\n' "$snapshot_components" > "$_snap_comp_file"

    awk '
      FILENAME == ARGV[1] { doc[$0] = 1; next }
      $0 != "" && !($0 in doc) { print }
    ' "$_doc_comp_file" "$_snap_comp_file" > "$additions_file"
    if [ -s "$additions_file" ]; then
      added="$(wc -l < "$additions_file" | tr -d ' ')"
    fi

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
        printf 'sync-derived-artifacts.sh: no component section found — expected "## N. Components & Design System", "## N. Components", or "## Component Inventory"\n' >&2
        rm -f "$additions_file"
        exit 1
      fi
    fi
    rm -f "$additions_file"

    if [ "$added" -eq 0 ]; then
      printf 'sync: ux-design.md is up to date — no components to add\n'
    fi
  fi

  # === Removal report (design-system pass only) ===
  # A design-system snapshot with zero components and zero templates must
  # still produce the absence report for any doc component. The snapshot's
  # projected components (union of .components + .templates) is the source.
  # The product-design projection sets components=[], so this check runs
  # only on the design-system pass to avoid false absence reports.
  #
  # Reuses the pre-computed $snapshot_components and $doc_components from
  # the addition phase (both were extracted before additions). Additions
  # are by definition present in the snapshot, so they can never be absent;
  # the pre-addition doc_components is the correct set to check.
  local _reported_absent=false
  if [ "$_sync_project" = "design_system" ]; then
    # When has_components was false, doc_components was never extracted;
    # we need to extract it for the zero-components-in-snapshot case.
    # But when the addition phase already extracted it (even if the result
    # was empty), re-extracting would re-read the doc after additions —
    # wasting O(N) subprocesses on content we already know is absent.
    if [ "$_doc_components_extracted" = false ] && _has_component_heading "$ux_doc"; then
      doc_components="$(_extract_doc_components "$ux_doc")"
    fi
    if [ -n "$doc_components" ]; then
      # Single awk pass to find doc components absent from the snapshot
      local _absent_file="$_sync_tmpdir/absent-components"
      local _snap_file="$_sync_tmpdir/snap-for-absent"
      if [ -n "$snapshot_components" ]; then
        printf '%s\n' "$snapshot_components" > "$_snap_file"
      else
        : > "$_snap_file"
      fi
      local _doc_absent_file="$_sync_tmpdir/doc-for-absent"
      printf '%s\n' "$doc_components" > "$_doc_absent_file"
      awk '
        FILENAME == ARGV[1] { snap[$0] = 1; next }
        $0 != "" && !($0 in snap) { print }
      ' "$_snap_file" "$_doc_absent_file" > "$_absent_file"
      if [ -s "$_absent_file" ]; then
        while IFS= read -r component; do
          printf 'sync: component "%s" is in ux-design.md but absent from the project snapshot (not removed — reporting only)\n' "$component"
          _reported_absent=true
        done < "$_absent_file"
      fi
    fi
  fi

  # === Screen reporting ===
  if [ "$has_screens" = true ]; then
    # --- Single-jq validation pass ---
    # One jq call validates all screens: field types, name control chars,
    # and content type. Emits "OK" or a single error line.
    # Validate screen filenames before any processing
    local scr_files
    scr_files="$(jq -r '.screens[].file' "$snapshot_file")" || true
    if [ -n "$scr_files" ]; then
      while IFS= read -r scr_fn; do
        if ! safe_filename_check "$scr_fn"; then
          printf 'sync-derived-artifacts.sh: unsafe screen filename rejected\n' >&2
          exit 1
        fi
        # Reject shell-meta characters in screen filenames
        # shellcheck disable=SC2016
        case "$scr_fn" in
          *'$('*|*'`'*|*'|'*|*'>'*|*'<'*|*'&'*|*';'*)
            printf 'sync-derived-artifacts.sh: unsafe screen filename (shell meta-characters): %s\n' "$scr_fn" >&2
            exit 1
            ;;
        esac
      done <<< "$scr_files"
    fi

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
      # Normalise: legacy flat array → per-project object → slice to target key's files
      # Validate every filename and hash via shared jq defs (fail closed)
      jq -r --arg proj "$_sync_project" "
        ${SAFE_FILENAME_JQ_DEF}
        ${SAFE_HASH_JQ_DEF}
        if type == \"array\" then
          {\"design_system\": {\"files\": .}, \"product_design\": {\"files\": []}}
        else . end
        | .[\$proj].files // []
        | .[] | (.file | safe_filename) as \$f | (.hash | safe_hash) as \$h
        | \"\(\$f)\t\(\$h)\"
      " "$baseline_path" > "$baseline_index" || {
        _die "unsafe or malformed baseline: $baseline_path"
      }
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
        printf '<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>\n'
        escape_boundary_markers < "$content_file"
        # Ensure the closing marker is on its own line
        if [ -s "$content_file" ] && [ "$(tail -c 1 "$content_file" | wc -l)" -eq 0 ]; then
          printf '\n'
        fi
        printf '<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>\n'
      elif [ "$content_hash" != "$baseline_hash" ]; then
        # Content changed
        printf 'sync: screen "%s" changed (file: %s)\n' "$screen_name" "$screen_file"
        printf '<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>\n'
        escape_boundary_markers < "$content_file"
        # Ensure the closing marker is on its own line
        if [ -s "$content_file" ] && [ "$(tail -c 1 "$content_file" | wc -l)" -eq 0 ]; then
          printf '\n'
        fi
        printf '<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>\n'
      fi
      # Unchanged screens: no report
    done < "$screen_meta"
  fi

  # === Flow reporting (product_design pass only, same treatment as screens) ===
  if [ "$has_flows" = true ]; then
    local flow_validation
    flow_validation="$(jq -r '
      .flows | to_entries[] |
      if (.value.name | type) != "string" then
        "ERR\t.flows[\(.key)].name must be a string, got \(.value.name | type)"
      elif (.value.file | type) != "string" then
        "ERR\t.flows[\(.key)].file must be a string, got \(.value.file | type)"
      elif (.value.name | test("[[:cntrl:]]")) then
        "ERR_CTRL\t\(.value.name)"
      elif (.value.content | type) != "string" then
        "ERR_CONTENT\t\(.value.name)\t\(.value.content | type)\t\(.value.file)"
      else empty end
    ' "$snapshot_file" | head -1)" || true

    if [ -n "$flow_validation" ]; then
      local flow_err_kind
      flow_err_kind="${flow_validation%%	*}"
      case "$flow_err_kind" in
        ERR)
          local flow_err_msg="${flow_validation#*	}"
          printf 'sync-derived-artifacts.sh: %s\n' "$flow_err_msg" >&2
          exit 1
          ;;
        ERR_CTRL)
          local flow_bad_name="${flow_validation#*	}"
          printf 'sync-derived-artifacts.sh: invalid flow name (contains control characters): %q\n' "$flow_bad_name" >&2
          exit 1
          ;;
        ERR_CONTENT)
          local flow_rest="${flow_validation#*	}"
          local flow_name="${flow_rest%%	*}"
          flow_rest="${flow_rest#*	}"
          local flow_type="${flow_rest%%	*}"
          local flow_file="${flow_rest#*	}"
          printf 'sync-derived-artifacts.sh: flow "%s" has invalid content (type: %s, expected string; file: %s)\n' \
            "$flow_name" "$flow_type" "$flow_file" >&2
          exit 1
          ;;
      esac
    fi

    # Validate flow filenames via safe-filename and shell-meta rejection
    local flow_files
    flow_files="$(jq -r '.flows[].file' "$snapshot_file")" || true
    if [ -n "$flow_files" ]; then
      while IFS= read -r flow_fn; do
        if ! safe_filename_check "$flow_fn"; then
          printf 'sync-derived-artifacts.sh: unsafe flow filename rejected\n' >&2
          exit 1
        fi
        # Reject shell-meta characters in flow filenames
        # shellcheck disable=SC2016
        case "$flow_fn" in
          *'$('*|*'`'*|*'|'*|*'>'*|*'<'*|*'&'*|*';'*)
            printf 'sync-derived-artifacts.sh: unsafe flow filename (shell meta-characters): %s\n' "$flow_fn" >&2
            exit 1
            ;;
        esac
      done <<< "$flow_files"
    fi

    local flow_meta="$_sync_tmpdir/flow-meta"
    jq -r '.flows | to_entries[] | "\(.key)\t\(.value.name)\t\(.value.file)"' \
      "$snapshot_file" > "$flow_meta"

    # Extract flow content
    local flow_content_dir="$_sync_tmpdir/flow-contents"
    mkdir -p "$flow_content_dir"
    local flow_lengths="$_sync_tmpdir/flow-lengths"
    jq -r '[.flows[].content | utf8bytelength] | .[]' "$snapshot_file" > "$flow_lengths"
    local flow_concat="$_sync_tmpdir/flow-all"
    jq -j '[.flows[].content] | join("")' "$snapshot_file" > "$flow_concat"

    local fidx=0
    exec 4< "$flow_concat"
    while IFS= read -r flen; do
      if [ "$flen" -gt 0 ]; then
        dd bs="$flen" count=1 of="$flow_content_dir/$fidx" 2>/dev/null <&4
      else
        : > "$flow_content_dir/$fidx"
      fi
      fidx=$((fidx + 1))
    done < "$flow_lengths"
    exec 4<&-

    while IFS=$'\t' read -r fidx flow_name flow_file; do
      local flow_content_file="$flow_content_dir/$fidx"
      printf 'sync: flow "%s" (file: %s)\n' "$flow_name" "$flow_file"
      printf '<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>\n'
      escape_boundary_markers < "$flow_content_file"
      if [ -s "$flow_content_file" ] && [ "$(tail -c 1 "$flow_content_file" | wc -l)" -eq 0 ]; then
        printf '\n'
      fi
      printf '<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>\n'
    done < "$flow_meta"
  fi

  # === Token reconciliation (design_system pass only) ===
  if [ "$_sync_project" = "design_system" ]; then
    local has_tokens=false
    if jq -e '.tokens' "$snapshot_file" >/dev/null 2>&1; then
      local tokens_type
      tokens_type="$(jq -r '.tokens | type' "$snapshot_file")"
      if [ "$tokens_type" = "object" ]; then
        has_tokens=true
      else
        printf 'sync-derived-artifacts.sh: invalid token data: tokens must be an object, got %s\n' "$tokens_type" >&2
      fi
    fi

    if [ "$has_tokens" = true ]; then
      local tok_baseline_path
      tok_baseline_path="$(_resolve_token_baseline "$_token_baseline_arg")"

      if [ -z "$tok_baseline_path" ]; then
        printf 'sync-derived-artifacts.sh: no project config folder found — skipping token baseline write\n' >&2
      else
        local new_tokens_file="$_sync_tmpdir/new-tokens.json"
        jq -S '.tokens' "$snapshot_file" > "$new_tokens_file"

        # Validate that .tokens is a flat object with string values
        local tok_shape_ok=true
        local tok_shape_err
        tok_shape_err="$(jq -r '
          if type != "object" then "tokens must be an object, got \(type)"
          else (to_entries[] | select(.value | type != "string")
                | "token \(.key) has non-string value (type: \(.value | type))") // empty
          end
        ' "$new_tokens_file" 2>/dev/null | head -1)" || true
        if [ -n "$tok_shape_err" ]; then
          printf 'sync-derived-artifacts.sh: invalid token data: %s\n' "$tok_shape_err" >&2
          tok_shape_ok=false
        fi
        if [ "$tok_shape_ok" = false ]; then
          printf 'sync-derived-artifacts.sh: skipping token reconciliation due to invalid token shape\n' >&2
        else

        # Check for tokens with control characters in name or value — skip them
        local bad_tokens
        bad_tokens="$(jq -r 'to_entries[] | select((.key | test("[[:cntrl:]]")) or (.value | test("[[:cntrl:]]"))) | .key' "$new_tokens_file" 2>/dev/null)" || true
        if [ -n "$bad_tokens" ]; then
          while IFS= read -r bad_tok; do
            printf 'sync-derived-artifacts.sh: skipping token with control character in name or value: %q\n' "$bad_tok" >&2
          done <<< "$bad_tokens"
          # Remove bad tokens from the working file
          jq 'with_entries(select((.key | test("[[:cntrl:]]") | not) and (.value | test("[[:cntrl:]]") | not)))' "$new_tokens_file" > "$_sync_tmpdir/clean-tokens.json"
          mv -f "$_sync_tmpdir/clean-tokens.json" "$new_tokens_file"
        fi

        # Reconciliation: compare with existing baseline
        local _skip_baseline_write=false
        if [ -f "$tok_baseline_path" ]; then
          # Validate the existing baseline shape before consuming it
          local bl_shape_rc=0
          jq -e 'type == "object" and (to_entries | all(.value | type == "string"))' \
            "$tok_baseline_path" >/dev/null 2>&1 || bl_shape_rc=$?
          if [ "$bl_shape_rc" -ne 0 ]; then
            printf 'sync-derived-artifacts.sh: malformed token baseline (expected flat object with string values): %s\n' \
              "$tok_baseline_path" >&2
            printf 'sync-derived-artifacts.sh: skipping reconciliation and preserving the malformed baseline\n' >&2
            _skip_baseline_write=true
          else

          # Screen baseline values for control characters — a hand-edited
          # baseline with tabs or newlines would break the TSV changed-tokens
          # file. Remove offending entries before consumption.
          local _clean_baseline_path="$tok_baseline_path"
          local bl_bad_values
          bl_bad_values="$(jq -r 'to_entries[] | select((.key | test("[[:cntrl:]]")) or (.value | test("[[:cntrl:]]"))) | .key' "$tok_baseline_path" 2>/dev/null)" || true
          if [ -n "$bl_bad_values" ]; then
            while IFS= read -r bl_bad_key; do
              printf 'sync-derived-artifacts.sh: baseline token with control character in name or value: %q — removing from comparison\n' "$bl_bad_key" >&2
            done <<< "$bl_bad_values"
            # Write a cleaned copy for use as the comparison baseline.
            # The original file is never modified. The new (clean) values
            # should replace the dirty baseline on the next write.
            _clean_baseline_path="$_sync_tmpdir/clean-baseline.json"
            jq 'with_entries(select((.key | test("[[:cntrl:]]") | not) and (.value | test("[[:cntrl:]]") | not)))' \
              "$tok_baseline_path" > "$_clean_baseline_path"
          fi

          # Read the product_design screens from the ORIGINAL combined snapshot
          local pd_screens_file="$_sync_tmpdir/pd-screens.json"
          if [ "$_is_combined" = true ]; then
            jq '.product_design.screens // []' "$_orig_snapshot_file" > "$pd_screens_file" 2>/dev/null || printf '[]\n' > "$pd_screens_file"
          else
            jq '.screens // []' "$_orig_snapshot_file" > "$pd_screens_file" 2>/dev/null || printf '[]\n' > "$pd_screens_file"
          fi

          # Validate screen structure before consuming entries.
          # First check the top-level type, then validate each element.
          local _pd_screen_err=""
          local _pd_type
          _pd_type="$(jq -r 'type' "$pd_screens_file" 2>/dev/null)" || _pd_type="unknown"
          if [ "$_pd_type" != "array" ]; then
            _pd_screen_err="screens must be an array, got ${_pd_type}"
          else
            _pd_screen_err="$(jq -r '
              .[] |
              if type != "object" then
                "screen entry must be an object, got \(type)"
              elif (.name | type) != "string" then
                "screen entry has non-string name (type: \(.name | type))"
              elif (.name | test("[[:cntrl:]]")) then
                "screen name contains control characters"
              elif (.content | type) != "string" then
                "screen \(.name) has non-string content (type: \(.content | type))"
              else empty end
            ' "$pd_screens_file" 2>/dev/null | head -1)" || true
          fi
          if [ -n "$_pd_screen_err" ]; then
            printf 'sync-derived-artifacts.sh: invalid product screen data: %s — skipping token-screen reconciliation\n' \
              "$_pd_screen_err" >&2
            # Replace with empty array so reconciliation has no screens to match
            printf '[]\n' > "$pd_screens_file"
            # Do not advance the baseline — the change must be re-evaluated
            # after the data is fixed (same behaviour as malformed baseline).
            _skip_baseline_write=true
          fi

          local old_tokens_file="$_clean_baseline_path"
          # Find changed tokens and check against screen content.
          # Uses unit separator (\u001f) between fields so that empty
          # values are preserved. Tab would collapse empty fields in
          # IFS-based read. Control characters are already rejected in
          # token names and values, so \u001f cannot appear in data.
          local changed_tokens="$_sync_tmpdir/changed-tokens"
          jq -r --slurpfile old "$old_tokens_file" '
            to_entries[] |
            select($old[0][.key] != null and $old[0][.key] != .value) |
            "\(.key)\u001f\($old[0][.key])\u001f\(.value)"
          ' "$new_tokens_file" > "$changed_tokens" 2>/dev/null || true

          # Also find removed tokens (in baseline, absent from new)
          local removed_tokens="$_sync_tmpdir/removed-tokens"
          jq -r --slurpfile newt "$new_tokens_file" '
            to_entries[] |
            select($newt[0][.key] == null) |
            .key
          ' "$old_tokens_file" > "$removed_tokens" 2>/dev/null || true

          if [ -s "$changed_tokens" ]; then
            # Pre-extract screen names and content once for efficient matching
            local screen_count
            screen_count="$(jq 'length' "$pd_screens_file")"
            local scr_names_file="$_sync_tmpdir/scr-names.tsv"
            jq -r '.[] | .name' "$pd_screens_file" > "$scr_names_file" 2>/dev/null || true

            # Split screen contents into individual files using dd
            local scr_content_dir="$_sync_tmpdir/scr-contents"
            mkdir -p "$scr_content_dir"
            if [ "$screen_count" -gt 0 ]; then
              local scr_lengths_file="$_sync_tmpdir/scr-lengths"
              jq -r '[.[].content // "" | utf8bytelength] | .[]' "$pd_screens_file" > "$scr_lengths_file"
              local scr_concat_file="$_sync_tmpdir/scr-all"
              jq -j '[.[].content // ""] | join("")' "$pd_screens_file" > "$scr_concat_file"

              # Replace NUL bytes with spaces in one pass over the joined
              # file before splitting.  A NUL is not an identifier character,
              # so replacing it with a space (also non-identifier) keeps
              # boundary detection correct and preserves byte lengths for dd.
              tr '\000' ' ' < "$scr_concat_file" > "$scr_concat_file.clean" \
                && mv -f "$scr_concat_file.clean" "$scr_concat_file"

              local scr_idx=0
              exec 5< "$scr_concat_file"
              while IFS= read -r scr_len; do
                if [ "$scr_len" -gt 0 ]; then
                  dd bs="$scr_len" count=1 of="$scr_content_dir/$scr_idx" 2>/dev/null <&5
                else
                  : > "$scr_content_dir/$scr_idx"
                fi
                scr_idx=$((scr_idx + 1))
              done < "$scr_lengths_file"
              exec 5<&-
            fi

            # Pre-escape all token values through the shared helper.
            # Build a TSV: raw_name \t safe_name \t safe_old \t safe_new.
            # Input uses unit separator (\037) to preserve empty fields.
            # First write an intermediate file with \037-separated columns
            # (raw_name, name, old, new), then cut fields 2-4, pipe
            # through escape_boundary_markers, and paste back to field 1.
            # This keeps the escape rule in one place.
            local tok_safe_file="$_sync_tmpdir/tok-safe.tsv"
            local tok_raw_file="$_sync_tmpdir/tok-raw.tsv"
            : > "$tok_raw_file"
            while IFS=$'\037' read -r tok_name tok_old tok_new; do
              printf '%s\037%s\037%s\037%s\n' "$tok_name" "$tok_name" "$tok_old" "$tok_new" >> "$tok_raw_file"
            done < "$changed_tokens"
            # Cut field 1 (raw, unescaped) and fields 2-4 (to escape).
            # Pipe fields 2-4 through the shared helper, then paste with
            # field 1 to produce the final tab-separated safe table.
            paste -d$'\t' \
              <(cut -d$'\037' -f1 "$tok_raw_file") \
              <(cut -d$'\037' -f2- "$tok_raw_file" | tr '\037' '\t' | escape_boundary_markers) \
              > "$tok_safe_file"

            # Pre-escape all screen names through the shared helper.
            local scr_safe_file="$_sync_tmpdir/scr-safe-names.tsv"
            local _sn_idx=0
            while IFS= read -r _sn_raw; do
              printf '%d\t%s\n' "$_sn_idx" "$_sn_raw"
              _sn_idx=$((_sn_idx + 1))
            done < "$scr_names_file" | escape_boundary_markers > "$scr_safe_file"

            # Build a file listing all screen content files that exist and
            # are non-empty, with their index.
            local scr_files_list="$_sync_tmpdir/scr-files-list"
            : > "$scr_files_list"
            local si=0
            while [ "$si" -lt "$screen_count" ]; do
              if [ -s "$scr_content_dir/$si" ]; then
                printf '%d\t%s\n' "$si" "$scr_content_dir/$si" >> "$scr_files_list"
              fi
              si=$((si + 1))
            done

            # Single awk pass: read changed tokens, read screen names,
            # then scan each screen content file for token references.
            # Token-major order: for each token, list affected screens.
            #
            # Two matching paths, both literal (no token-derived regex):
            #
            # 1. Identifier-only tokens (all chars in [A-Za-z0-9_-]):
            #    split the content into maximal identifier runs ONCE per
            #    screen using a FIXED non-identifier regex, build a set,
            #    then look up each token.  Linear on gawk and mawk;
            #    slower on macOS awk for very large screens because
            #    split() with a regex separator costs length * matches.
            #
            # 2. Tokens with non-identifier chars (--a.b, --p(1), etc.):
            #    literal index() walk.  These tokens are rare in practice
            #    (non-identifier chars are not valid unescaped in CSS
            #    custom property names), so the walk cost is acceptable.
            #
            # Total: 1 awk subprocess regardless of T and S.
            awk -F'\t' '
              # Pass 1: read token safe table (raw, safe, old, new)
              FILENAME == ARGV[1] {
                nt++
                traw[nt] = $1; tsafe[nt] = $2; told[nt] = $3; tnew[nt] = $4
                next
              }
              # Pass 2: read screen safe names (idx, safe_name)
              FILENAME == ARGV[2] {
                sname[$1] = $2
                next
              }
              # Pass 3: read screen file list (idx, path)
              FILENAME == ARGV[3] {
                nscr++
                scr_idx[nscr] = $1; scr_path[nscr] = $2
                next
              }
              END {
                # Identifier boundary chars
                id_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"

                # Classify each token: id-only or mixed.
                for (t = 1; t <= nt; t++) {
                  tok = traw[t]
                  tok_is_id[t] = 1
                  for (c = 1; c <= length(tok); c++) {
                    if (index(id_chars, substr(tok, c, 1)) == 0) {
                      tok_is_id[t] = 0
                      break
                    }
                  }
                }

                # Pre-read all screen contents into memory
                for (s = 1; s <= nscr; s++) {
                  scr_content[s] = ""
                  while ((getline line < scr_path[s]) > 0)
                    scr_content[s] = scr_content[s] line "\n"
                  close(scr_path[s])
                }

                # Token-major: for each token, scan all screens
                nhits = 0
                for (t = 1; t <= nt; t++) {
                  tok = traw[t]
                  tlen = length(tok)
                  if (tlen == 0) continue
                  for (s = 1; s <= nscr; s++) {
                    content = scr_content[s]
                    clen = length(content)
                    if (clen == 0) continue

                    found = 0

                    if (tok_is_id[t]) {
                      # Fast path: split into identifier runs once per
                      # screen (cached), then do a set lookup.  Linear
                      # on gawk and mawk; slower on macOS awk for very
                      # large screens.
                      if (!(s in scr_runs_n)) {
                        scr_runs_n[s] = split(content, _tmp_runs, \
                          /[^ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]+/)
                        for (_r = 1; _r <= scr_runs_n[s]; _r++)
                          scr_run_set[s, _tmp_runs[_r]] = 1
                      }
                      if ((s, tok) in scr_run_set)
                        found = 1
                    } else {
                      # Slow path: literal index() walk for tokens that
                      # contain non-identifier characters.
                      pos = 1
                      while (pos <= clen - tlen + 1) {
                        hit = index(substr(content, pos), tok)
                        if (hit == 0) break
                        abs = pos + hit - 1

                        # Left boundary
                        if (abs > 1) {
                          lch = substr(content, abs - 1, 1)
                          before_ok = (index(id_chars, lch) == 0)
                        } else {
                          before_ok = 1
                        }
                        # Right boundary
                        rpos = abs + tlen
                        if (rpos <= clen) {
                          rch = substr(content, rpos, 1)
                          after_ok = (index(id_chars, rch) == 0)
                        } else {
                          after_ok = 1
                        }
                        if (before_ok && after_ok) {
                          found = 1
                          break
                        }
                        pos = abs + 1
                      }
                    }

                    if (found) {
                      nhits++
                      hit_line[nhits] = sprintf("reconciliation (medium): token %s %s -> %s affects screen %s", tsafe[t], told[t], tnew[t], sname[scr_idx[s]])
                    }
                  }
                }

                # Print all findings in token-major order
                for (h = 1; h <= nhits; h++)
                  print hit_line[h]
              }
            ' "$tok_safe_file" "$scr_safe_file" "$scr_files_list"
          fi

          # Report removed tokens (the design system no longer defines them)
          if [ -s "$removed_tokens" ]; then
            while IFS= read -r removed_tok; do
              local safe_removed_tok
              safe_removed_tok="$(printf '%s' "$removed_tok" | escape_boundary_markers)"
              printf 'reconciliation (medium): token %s was removed from the design system\n' "$safe_removed_tok"
            done < "$removed_tokens"
          fi

          fi  # end baseline shape validation guard
        fi

        # Write new baseline (tempfile in the target directory for atomicity)
        if [ "$_skip_baseline_write" = false ]; then
          local tok_baseline_dir
          tok_baseline_dir="$(dirname "$tok_baseline_path")"
          if mkdir -p "$tok_baseline_dir" 2>/dev/null; then
            local tok_tmp
            tok_tmp="$(mktemp "${tok_baseline_dir}/tok-baseline-tmp.XXXXXX" 2>/dev/null)" || true
            if [ -z "$tok_tmp" ]; then
              printf 'sync-derived-artifacts.sh: state directory %s is not writable — skipping baseline write\n' \
                "$tok_baseline_dir" >&2
            elif cp "$new_tokens_file" "$tok_tmp"; then
              mv -f "$tok_tmp" "$tok_baseline_path"
            else
              rm -f "$tok_tmp"
              printf 'sync-derived-artifacts.sh: failed to write token baseline — cleaned up temp file\n' >&2
            fi
          else
            printf 'sync-derived-artifacts.sh: could not create state directory %s — skipping baseline write\n' \
              "$tok_baseline_dir" >&2
          fi
        fi

        fi  # end tok_shape_ok else
      fi
    fi
  fi

  # If no components and no screens and no flows, report up to date — but
  # not when the absence report already ran (that would read as a contradiction).
  if [ "$has_components" = false ] && [ "$has_screens" = false ] && [ "$has_flows" = false ] \
     && [ "$_reported_absent" = false ]; then
    printf 'sync: ux-design.md is up to date — no components to add\n'
  fi
}

_main "$@"
