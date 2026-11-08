#!/usr/bin/env bash
# mutation-config.sh — shared reads for mutation testing: thresholds from the
# project config, the evidence path, a story's priority and its File List.
#
# Sourceable, sets no shell options, keeps no state. Every producer and
# consumer goes through these functions so they cannot disagree on where the
# evidence lives or on what "thresholds configured" means.
#
# Provides:
#   mutation_read_thresholds <config>   compact JSON object on stdout, nothing
#                                       when the key is absent; `{}` counts as
#                                       present; non-zero with a message naming
#                                       yq when the key cannot be read
#   mutation_config_path                path of the project config, if any
#   mutation_evidence_path <story_key>  path of the story's mutation evidence
#   mutation_story_priority <story>     P0..P3 from the story frontmatter
#   mutation_story_file_list <story>    one path per line from the File List;
#                                       returns 1 when a line names no path
#
# bash 3.2 compatible.

_MC_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"

mutation_read_thresholds() {
  local config="$1" raw
  [ -f "$config" ] || return 0
  # awk rather than two greps: under pipefail a `grep -q` closing the pipe
  # early can read as "no match" and quietly turn the feature off.
  awk '!/^[[:space:]]*#/ && /mutation_thresholds/ { found = 1 } END { exit !found }' "$config" || return 0
  if ! command -v yq >/dev/null 2>&1; then
    printf 'error: yq is required to read test_execution.mutation_thresholds from %s but is not installed\n' "$config" >&2
    return 1
  fi
  if ! raw="$(yq -o=json -I=0 '.test_execution.mutation_thresholds' "$config" 2>&1)"; then
    printf 'error: yq failed to read test_execution.mutation_thresholds from %s: %s\n' "$config" "$raw" >&2
    return 1
  fi
  case "$raw" in
    ''|null) return 0 ;;
  esac
  printf '%s\n' "$raw"
}

mutation_config_path() {
  local PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-}}"
  if [ -z "$PROJECT_ROOT" ]; then
    PROJECT_ROOT="$("$_MC_LIB_DIR/../resolve-config.sh" --field project_root 2>/dev/null)" || PROJECT_ROOT=""
  fi
  local candidate
  for candidate in \
    "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/config/project-config.yaml" \
    "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}config/project-config.yaml"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

mutation_evidence_path() {
  local story_key="$1" artifacts="${GAIA_TEST_ARTIFACTS:-}"
  if [ -z "$artifacts" ]; then
    artifacts="$("$_MC_LIB_DIR/../resolve-config.sh" --field test_artifacts 2>/dev/null)" || artifacts=""
  fi
  if [ -z "$artifacts" ]; then
    local PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-}}"
    artifacts="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/test-artifacts"
  fi
  printf '%s/test-results/%s-mutation.json\n' "${artifacts%/}" "$story_key"
}

mutation_story_priority() {
  awk '
    NR > 1 && /^---[[:space:]]*$/ { exit }
    /^priority:/ {
      value = $2
      gsub(/["'"'"']/, "", value)
      if (value ~ /^P[0-3]$/) print value
      exit
    }
  ' "$1"
}

# Prints every path a story's File List names, one per line and each once, however
# the line writes it: backticked, bold, quoted, a link target, a table cell, a
# comma-separated list, with a label in front or a note or `:12` behind. A path
# is a token holding a slash or ending in an extension, or the first backticked
# word on a line. URLs are not paths.
# Headings, blank lines, table headers and separators, HTML comments and fence
# markers are ignored.  Paths inside a fence are read.  A list-item label
# ending in a colon (section heading for a nested list) and a bold line ending
# in a colon (section heading) are structural scaffolding and ignored.  Any
# other line that names no path cannot be read: it is reported on stderr and the
# function returns 1 after printing the rest.
mutation_story_file_list() {
  LC_ALL=C awk '
    BEGIN { SEPARATORS = " \t,;|()<>[]\"`:#=&+!?" sprintf("%c", 39) }
    function clean(t) {
      while (t ~ /^[*~]/) t = substr(t, 2)
      while (t ~ /[*~.]$/) t = substr(t, 1, length(t) - 1)
      if (length(t) > 2 && t ~ /^_.*_$/) t = substr(t, 2, length(t) - 2)
      sub(/^\.\//, "", t)
      return t
    }
    function has_extension(t) { return t ~ /\.[A-Za-z0-9_-]+$/ }
    function path_shaped(t) {
      if (t ~ /^-/ || t !~ /[A-Za-z0-9]/) return 0
      return index(t, "/") > 0 || has_extension(t)
    }
    function keep(t) {
      found++
      if (!(t in seen)) { seen[t] = 1; print t }
    }
    # Walks characters so that no awk has to agree on a bracket expression. Any
    # byte outside printable ASCII separates, so a dash glued to a path does not
    # become part of its extension.
    function scan_tokens(text,    i, c, token) {
      token = ""
      for (i = 1; i <= length(text) + 1; i++) {
        c = i <= length(text) ? substr(text, i, 1) : " "
        if (index(SEPARATORS, c) > 0 || c < " " || c > "~") {
          token = clean(token)
          if (path_shaped(token)) keep(token)
          token = ""
        } else {
          token = token c
        }
      }
    }
    function scan_span(span) {
      if (span ~ /[ \t]/) {
        if (span !~ /^-/ && has_extension(span)) keep(span)
      } else if (found == 0 && span ~ /^[A-Za-z0-9_@{}$][A-Za-z0-9_@{}$.-]*$/ && !path_shaped(span)) {
        keep(span)
      }
      scan_tokens(span)
    }
    # Returns how many paths the text names.
    function scan_text(text,    open_at, tail, close_at, outside) {
      found = 0
      while (match(text, /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^ \t)>]*/))
        text = substr(text, 1, RSTART - 1) " " substr(text, RSTART + RLENGTH)
      gsub(/\\/, "", text)
      outside = ""
      while ((open_at = index(text, "`")) > 0) {
        tail = substr(text, open_at + 1)
        close_at = index(tail, "`")
        if (close_at == 0) break
        outside = outside substr(text, 1, open_at - 1) " "
        scan_span(substr(tail, 1, close_at - 1))
        text = substr(tail, close_at + 1)
      }
      scan_tokens(outside text)
      return found
    }
    function is_table_separator(l) { return l ~ /^[ \t]*\|?[ \t:|-]*-[ \t:|-]*\|?[ \t]*$/ }
    /^(```|~~~)/ { in_fence = !in_fence }
    !in_fence && /^#+[ \t]/ {
      level = match($0, /[ \t]/) - 1
      if (level >= 2 && $0 ~ /^#+[ \t]+[Ff]ile [Ll]ist/) { in_list = 1; list_level = level; next }
      if (in_list && level <= list_level) in_list = 0
      next
    }
    in_list { lines[++count] = $0 }
    END {
      bad = 0
      in_fence = 0
      in_comment = 0
      for (n = 1; n <= count; n++) {
        line = lines[n]
        sub(/^[ \t]+/, "", line)
        if (line ~ /^(```|~~~)/) { in_fence = !in_fence; continue }
        if (in_comment) { if (index(line, "-->") > 0) in_comment = 0; continue }
        if (line ~ /^<!--/) { if (index(line, "-->") == 0) in_comment = 1; continue }
        if (line !~ /[A-Za-z0-9]/) continue
        if (line ~ /^\|/ && (n < count) && is_table_separator(lines[n + 1])) continue
        is_item = sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", line)
        if (scan_text(line) > 0) continue
        # A list-item label ending in a colon is a heading for a nested list.
        # A bold line ending in a colon is a section heading (e.g. **Modified:**).
        # Both are structural scaffolding; everything else naming no path is
        # unreadable.
        label = line; gsub(/[*_ \t]/, "", label)
        if (label ~ /:$/ && (is_item || line ~ /^\*\*.*\*\*$/)) continue
        printf "File List line cannot be read as a path: %s\n", lines[n] > "/dev/stderr"
        bad = 1
      }
      exit bad
    }
  ' "$1"
}
