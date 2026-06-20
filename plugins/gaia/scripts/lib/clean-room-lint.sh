#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# clean-room-lint.sh — static analysis for reviewer clean-room violations.
#
# Two modes:
#   --roster  SKILL_PATH    Scan a SKILL.md roster for reviewer personas.
#   --callsite DIR [DIR...] Scan shell source for spawn_teammate calls with
#                           reviewer-persona literals.
#
# Exits 0 if clean, 1 if violations found.

# ---------- Resolve reviewer-personas.txt ----------

_resolve_reviewer_list() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "${script_dir}/../../knowledge/reviewer-personas.txt"
}

# _load_reviewer_names — print reviewer persona names (one per line).
_load_reviewer_names() {
  local list_file
  list_file="$(_resolve_reviewer_list)"
  if [ ! -f "$list_file" ]; then
    printf 'clean-room-lint: reviewer-personas.txt not found at %s\n' "$list_file" >&2
    return 1
  fi
  grep -v '^#' "$list_file" | grep -v '^[[:space:]]*$'
}

# ---------- Mode: roster scan ----------

_lint_roster() {
  local skill_path="$1"
  if [ ! -f "$skill_path" ]; then
    printf 'clean-room-lint: file not found: %s\n' "$skill_path" >&2
    return 1
  fi

  # Extract YAML frontmatter between --- delimiters.
  local in_fm=0
  local frontmatter=""
  while IFS= read -r line; do
    if [ "$in_fm" -eq 0 ]; then
      if [ "$line" = "---" ]; then
        in_fm=1
        continue
      fi
    else
      if [ "$line" = "---" ]; then
        break
      fi
      frontmatter="${frontmatter}${line}
"
    fi
  done < "$skill_path"

  # Extract persona names from roster entries.
  local personas
  personas="$(printf '%s' "$frontmatter" | grep -E '^\s+persona:' | sed 's/.*persona:[[:space:]]*//' | sed 's/^gaia://' || true)"

  if [ -z "$personas" ]; then
    # No roster — clean.
    return 0
  fi

  local reviewer_names
  reviewer_names="$(_load_reviewer_names)" || return 1

  local violations=0
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$reviewer_names" | grep -qxF "$name"; then
      printf 'clean-room-lint: VIOLATION in %s — reviewer persona "%s" declared as teammate\n' \
        "$skill_path" "$name" >&2
      violations=$((violations + 1))
    fi
  done <<< "$personas"

  if [ "$violations" -gt 0 ]; then
    printf 'clean-room-lint: %d reviewer persona(s) found in roster\n' "$violations" >&2
    return 1
  fi
  return 0
}

# ---------- Mode: call-site scan ----------

_lint_callsite() {
  local dirs=("$@")
  if [ ${#dirs[@]} -eq 0 ]; then
    printf 'clean-room-lint: --callsite requires at least one directory\n' >&2
    return 1
  fi

  local reviewer_names
  reviewer_names="$(_load_reviewer_names)" || return 1

  # Build a grep pattern that matches spawn_teammate with any reviewer persona.
  # Matches both bare and gaia:-prefixed forms.
  local pattern=""
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -n "$pattern" ]; then
      pattern="${pattern}|"
    fi
    pattern="${pattern}spawn_teammate[[:space:]]+[\"']?(gaia:)?${name}[\"']?"
  done <<< "$reviewer_names"

  # Two-pass scan: grep -rn for candidate matches, then filter comments.
  local violations=0
  local match_line
  while IFS= read -r match_line; do
    [ -n "$match_line" ] || continue
    # match_line is "file:lineno:content"
    local file_path line_content
    file_path="${match_line%%:*}"
    line_content="${match_line#*:}"
    line_content="${line_content#*:}"

    # Skip .bats files.
    case "$file_path" in
      *.bats) continue ;;
    esac

    # Skip comment lines.
    local stripped="${line_content#"${line_content%%[![:space:]]*}"}"
    case "$stripped" in
      '#'*) continue ;;
    esac

    # Extract file:lineno prefix for the report.
    local file_loc
    file_loc="${match_line%%:"${line_content}"}"
    printf 'clean-room-lint: VIOLATION at %s — spawn_teammate call with reviewer persona\n' \
      "$file_loc" >&2
    printf '  %s\n' "$line_content" >&2
    violations=$((violations + 1))
  done < <(grep -rnE --include='*.sh' --include='*.bash' "$pattern" "${dirs[@]}" 2>/dev/null || true)

  if [ "$violations" -gt 0 ]; then
    printf 'clean-room-lint: %d call-site violation(s) found\n' "$violations" >&2
    return 1
  fi
  return 0
}

# ---------- Main ----------

main() {
  if [ $# -eq 0 ]; then
    printf 'Usage: clean-room-lint.sh --roster SKILL_PATH | --callsite DIR [DIR...]\n' >&2
    return 1
  fi

  local mode="$1"
  shift

  case "$mode" in
    --roster)
      if [ $# -eq 0 ]; then
        printf 'clean-room-lint: --roster requires a SKILL.md path\n' >&2
        return 1
      fi
      _lint_roster "$1"
      ;;
    --callsite)
      _lint_callsite "$@"
      ;;
    *)
      printf 'clean-room-lint: unknown mode "%s"\n' "$mode" >&2
      return 1
      ;;
  esac
}

main "$@"
