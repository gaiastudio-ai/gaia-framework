#!/usr/bin/env bash
# config-yaml-editor.sh — comment-preserving section editor for project-config.yaml
#
# Story: E71-S3 (/gaia-config-* editor family).
# ADR:   ADR-044 (Config Split — comment-preserving editing) and ADR-042
#        (Scripts-over-LLM — deterministic YAML manipulation belongs in scripts).
#
# Comment-preserving technique:
#   The script identifies top-level sections by scanning for unindented keys
#   matching ^[a-z_][a-z0-9_]*: at column 0. A section's line range is from its
#   header line to the line immediately before the next top-level key (or EOF).
#   Read/extract returns those lines verbatim. Replace splices the new section
#   lines into the same range, preserving every byte outside the range.
#
#   This line-level technique guarantees byte-identical preservation of every
#   comment (inline + block) and every formatting choice (indentation, blank
#   lines, multi-line scalars) outside the edited section. ADR-044 forbids
#   round-tripping through a generic YAML serializer (e.g., `yq -y`,
#   `yaml.dump`) because those strip comments.
#
# Usage:
#   config-yaml-editor.sh extract <file> <section_name>
#       Print the section's lines to stdout.
#       Exit 0 on success; exit 2 if section not found.
#
#   config-yaml-editor.sh replace <file> <section_name> <new_section_file>
#       Replace the section's lines in-place with the contents of
#       <new_section_file>. The new content's first line MUST be the section
#       header (e.g., "environments:") — the script does not synthesize it.
#       Exit 0 on success; exit 2 if section not found; exit 1 on I/O error.
#
#   config-yaml-editor.sh insert <file> <section_name> <new_section_file>
#       Insert (append) a brand-new section before EOF when it does not yet
#       exist. Exit 0 on success; exit 1 if section already exists.
#
#   config-yaml-editor.sh sections <file>
#       List all top-level section names found in the file (one per line).
#
# Exit codes:
#   0  success
#   1  generic error (bad args, I/O failure, section already exists for insert)
#   2  section not found (extract / replace)

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="config-yaml-editor.sh"
err()  { printf '%s: %s\n' "$prog" "$*" >&2; }
die()  { err "$*"; exit 1; }

if [ "$#" -lt 2 ]; then
  err "usage: $prog <extract|replace|insert|sections> <file> [args...]"
  exit 1
fi

CMD="$1"
FILE="$2"

[ -f "$FILE" ] || die "file not found: $FILE"

# find_range <section_name>
#   Prints "<start_line> <end_line>" (1-based, inclusive) on stdout when the
#   section is found; prints nothing and exits 1 when not found.
#
#   The section's range is from its header line to its last "owned" line —
#   meaning the last non-blank, non-comment line before the next top-level
#   key (or EOF). Blank lines and block comments that immediately precede
#   the next section are NOT absorbed into this section's range; they are
#   considered to belong to the next section's leading context. This matters
#   for replace operations that must not destroy block comments preceding
#   subsequent sections.
find_range() {
  local section="$1"
  awk -v target="$section" '
    function is_top_key(line,    key) {
      if (line !~ /^[a-z_][a-z0-9_]*:/) return ""
      key = line
      sub(/:.*/, "", key)
      return key
    }
    BEGIN { start = 0; last_owned = 0 }
    {
      key = is_top_key($0)
      if (key != "") {
        if (start == 0 && key == target) {
          start = NR
          last_owned = NR
          next
        }
        if (start != 0 && key != target) {
          # Hit the next top-level section; stop and report last_owned.
          exit
        }
      }
      if (start != 0) {
        # Within the target section. Track the last non-blank, non-comment
        # line so we exclude trailing blanks/comments that belong to the
        # next section.
        if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*#/) {
          last_owned = NR
        }
      }
    }
    END {
      if (start == 0) exit 1
      printf "%d %d\n", start, last_owned
    }
  ' "$FILE"
}

case "$CMD" in
  sections)
    # List every top-level section name (unindented key with trailing colon).
    awk '/^[a-z_][a-z0-9_]*:/ {
      key = $0
      sub(/:.*/, "", key)
      print key
    }' "$FILE"
    ;;

  extract)
    [ "$#" -ge 3 ] || die "usage: $prog extract <file> <section_name>"
    SECTION="$3"
    if range="$(find_range "$SECTION")"; then
      read -r START END <<<"$range"
      sed -n "${START},${END}p" "$FILE"
    else
      err "section not found: $SECTION"
      exit 2
    fi
    ;;

  replace)
    [ "$#" -ge 4 ] || die "usage: $prog replace <file> <section_name> <new_section_file>"
    SECTION="$3"
    NEW_FILE="$4"
    [ -f "$NEW_FILE" ] || die "new section file not found: $NEW_FILE"

    if ! range="$(find_range "$SECTION")"; then
      err "section not found: $SECTION"
      exit 2
    fi
    read -r START END <<<"$range"

    # AF-2026-05-31-3 / Test14 F-04 — same wrapper/section-name match check
    # as `insert`. Replacing a section with content whose top-level key
    # doesn't match the requested SECTION corrupts the file just as badly.
    _first_key="$(awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      /^[a-zA-Z0-9_]+:/ { sub(/:.*/,""); print; exit }
    ' "$NEW_FILE")"
    if [ -z "$_first_key" ]; then
      err "new section file is empty or has no top-level key: $NEW_FILE"
      err "expected the file to start with '$SECTION:' followed by the section body"
      exit 1
    fi
    if [ "$_first_key" != "$SECTION" ]; then
      err "wrapper mismatch: $NEW_FILE starts with '${_first_key}:' but the requested section is '$SECTION:'"
      err "wrap the contents under '$SECTION:' (matching the extract output shape), or invoke with the correct --section name"
      exit 1
    fi

    # Construct the new file: lines 1..(START-1) + new_section + lines (END+1)..EOF
    TMP="$(mktemp)"
    trap 'rm -f "$TMP"' EXIT

    if [ "$START" -gt 1 ]; then
      sed -n "1,$((START - 1))p" "$FILE" > "$TMP"
    else
      : > "$TMP"
    fi
    cat "$NEW_FILE" >> "$TMP"
    # Ensure new section content ends with a newline before tail-splice.
    if [ -s "$NEW_FILE" ] && [ "$(tail -c1 "$NEW_FILE" | od -An -c | tr -d ' ')" != '\n' ]; then
      printf '\n' >> "$TMP"
    fi
    # Append everything after END
    sed -n "$((END + 1)),\$p" "$FILE" >> "$TMP"

    mv "$TMP" "$FILE"
    trap - EXIT
    ;;

  insert)
    [ "$#" -ge 4 ] || die "usage: $prog insert <file> <section_name> <new_section_file>"
    SECTION="$3"
    NEW_FILE="$4"
    [ -f "$NEW_FILE" ] || die "new section file not found: $NEW_FILE"

    # AC5 (E71-S7) — schema-aware fail-safe: reject section names that are not
    # declared as top-level properties in project-config.schema.json. This
    # closes the wrong-section-name defect class that let /gaia-config-tool
    # ship writes against the nonexistent `tool_adapters` section and
    # /gaia-config-rubric against the nonexistent `rubrics` section. Closed
    # set is the keys of `.properties` in the schema.
    SCHEMA_PATH="$(dirname "$0")/../schemas/project-config.schema.json"
    if [ -f "$SCHEMA_PATH" ] && command -v jq >/dev/null 2>&1; then
      if ! jq -r '.properties | keys[]' "$SCHEMA_PATH" 2>/dev/null \
          | grep -Fxq "$SECTION"; then
        err "unknown section: '$SECTION' is not a declared property in $SCHEMA_PATH"
        err "consult the schema's .properties keys for the closed set of accepted names"
        exit 1
      fi
    fi

    if find_range "$SECTION" >/dev/null 2>&1; then
      err "section already exists: $SECTION"
      exit 1
    fi

    # AF-2026-05-31-3 / Test14 F-04 — wrapper/section-name match check.
    # The prior implementation appended NEW_FILE verbatim to EOF without
    # checking that NEW_FILE's top-level YAML key actually matched the
    # requested SECTION. An operator passing unwrapped (inner-only)
    # content silently wrote those keys at the FILE's ROOT level and the
    # script returned exit 0 — corrupting project-config.yaml in a way
    # the schema validator only caught much later. Skip blank lines and
    # comments to find the first non-comment top-level key (a left-anchored
    # `[a-z_]+:` line); if it isn't `<SECTION>:`, refuse with a clear
    # message naming the expected wrapper form.
    _first_key="$(awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      /^[a-zA-Z0-9_]+:/ { sub(/:.*/,""); print; exit }
    ' "$NEW_FILE")"
    if [ -z "$_first_key" ]; then
      err "new section file is empty or has no top-level key: $NEW_FILE"
      err "expected the file to start with '$SECTION:' followed by the section body"
      exit 1
    fi
    if [ "$_first_key" != "$SECTION" ]; then
      err "wrapper mismatch: $NEW_FILE starts with '${_first_key}:' but the requested section is '$SECTION:'"
      err "wrap the contents under '$SECTION:' (matching the extract output shape), or invoke with the correct --section name"
      exit 1
    fi

    # Append new section to end-of-file with a leading blank-line separator.
    {
      cat "$FILE"
      # Ensure file ends with a newline before adding the separator
      if [ -s "$FILE" ] && [ "$(tail -c1 "$FILE" | od -An -c | tr -d ' ')" != '\n' ]; then
        printf '\n'
      fi
      printf '\n'
      cat "$NEW_FILE"
      if [ -s "$NEW_FILE" ] && [ "$(tail -c1 "$NEW_FILE" | od -An -c | tr -d ' ')" != '\n' ]; then
        printf '\n'
      fi
    } > "${FILE}.tmp"
    mv "${FILE}.tmp" "$FILE"
    ;;

  *)
    die "unknown command: $CMD"
    ;;
esac
