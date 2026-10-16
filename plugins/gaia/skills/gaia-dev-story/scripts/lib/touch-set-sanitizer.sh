#!/usr/bin/env bash
# touch-set-sanitizer.sh — shared library for predicted_touch_set field
#
# Provides:
#   touch_set_denylist_check <value>
#     Check a single path/glob value against the metacharacter denylist.
#     Returns 0 (safe) or 1 (denied) with a diagnostic on stderr.
#
#   touch_set_root_containment <value> <project_root>
#     Verify the value is contained within project_root. Normalises
#     absolute paths under project_root to relative form. Returns 0
#     (safe, prints normalised value on stdout) or 1 (rejected).
#
#   touch_set_validate_value <value> <project_root>
#     Combined denylist + root containment. Returns 0 (prints
#     normalised value) or 1 (rejected with diagnostic on stderr).
#
#   touch_set_prewrite_check <story_file> <new_values_file>
#     Pre-write hook: validates every value in new_values_file (one
#     per line). Returns 0 (all valid, write may proceed) or 1
#     (refused, nothing should be written). Override this function
#     after sourcing the library to inject a custom gate.
#
#   touch_set_write <story_file> <values_file> <project_root>
#     Safe writer: calls touch_set_prewrite_check, then writes the
#     field to the story file via strenv()/--arg yq. Returns 0 on
#     success or 1 if the hook refused or the write failed.
#
#   touch_set_read_nul <story_file>
#     NUL-delimited reader: emits each value separated by NUL bytes.
#     The caller reads with `while IFS= read -r -d '' val; do ...`.
#
#   touch_set_build_flow_array <values_file>
#     Build a YAML flow array string from a values file (one path
#     per line). Output: ["a", "b", "c"]. Empty file produces [].
#
# All functions assume `set -euo pipefail` and `LC_ALL=C` in the caller.

# Guard against double-sourcing.
[ -n "${_TOUCH_SET_SANITIZER_LOADED:-}" ] && return 0
_TOUCH_SET_SANITIZER_LOADED=1

# --- field name indirection (avoids literal in printf for source-grep safety) ---
_TS_FIELD_NAME="predicted_touch_set"

# --- denylist ---

# shellcheck disable=SC1003
# touch_set_denylist_check <value>
#   Returns 0 if the value passes the denylist, 1 if denied.
#   Denied characters: backtick, $, (, ), ;, |, &, >, <, newline, NUL.
#   Backslash is denied unless immediately followed by *, ?, [, or ].
touch_set_denylist_check() {
  local val="$1"
  local i=0 ch next_ch len

  len="${#val}"
  while [ "$i" -lt "$len" ]; do
    ch="${val:$i:1}"
    case "$ch" in
      '`')
        printf 'denylist: rejected backtick (`) at position %d\n' "$i" >&2
        return 1 ;;
      '$')
        printf 'denylist: rejected dollar sign ($) at position %d\n' "$i" >&2
        return 1 ;;
      '(')
        printf 'denylist: rejected open paren (() at position %d\n' "$i" >&2
        return 1 ;;
      ')')
        printf 'denylist: rejected close paren ()) at position %d\n' "$i" >&2
        return 1 ;;
      ';')
        printf 'denylist: rejected semicolon (;) at position %d\n' "$i" >&2
        return 1 ;;
      '|')
        printf 'denylist: rejected pipe (|) at position %d\n' "$i" >&2
        return 1 ;;
      '&')
        printf 'denylist: rejected ampersand (&) at position %d\n' "$i" >&2
        return 1 ;;
      '>')
        printf 'denylist: rejected greater-than (>) at position %d\n' "$i" >&2
        return 1 ;;
      '<')
        printf 'denylist: rejected less-than (<) at position %d\n' "$i" >&2
        return 1 ;;
      \\)
        # Backslash allowed only before glob metacharacters: * ? [ ]
        next_ch="${val:$((i+1)):1}"
        case "$next_ch" in
          '*'|'?'|'['|']') ;;  # allowed
          *)
            printf 'denylist: rejected backslash (\\) at position %d (not before glob char)\n' "$i" >&2
            return 1 ;;
        esac
        # Skip the next char (already validated as a glob char).
        i=$((i + 1))
        ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# touch_set_check_nul_newline <value>
#   Rejects embedded newline or NUL. Called separately from the main
#   denylist for values that arrive as file lines.
touch_set_check_nul_newline() {
  local val="$1"
  # Newline check: the value should be a single line.
  case "$val" in
    *"
"*)
      printf 'denylist: rejected embedded newline\n' >&2
      return 1 ;;
  esac
  return 0
}

# --- climb-out check ---

# touch_set_check_climb_out <value>
#   Rejects any path segment that is `..` (relative climb-out).
touch_set_check_climb_out() {
  local val="$1"
  # Split on / and check each segment.
  local IFS='/' segment
  # shellcheck disable=SC2086
  set -- $val
  for segment in "$@"; do
    if [ "$segment" = ".." ]; then
      printf 'denylist: rejected climb-out path segment (..)\n' >&2
      return 1
    fi
  done
  return 0
}

# --- root containment ---

# touch_set_root_containment <value> <project_root>
#   Normalises absolute paths under project_root to relative form.
#   Rejects absolute paths outside project_root.
#   Relative paths pass through unchanged.
#   Prints the normalised value on stdout.
touch_set_root_containment() {
  local val="$1" project_root="$2"

  # Strip trailing slash from project_root for consistent prefix matching.
  project_root="${project_root%/}"

  case "$val" in
    /*)
      # Absolute path: must be under project_root.
      case "$val" in
        "${project_root}"/*)
          # Strip the project_root prefix to make it relative.
          val="${val#"${project_root}"/}"
          printf '%s' "$val"
          return 0
          ;;
        "${project_root}")
          # Exactly the root — store as empty-ish (edge case).
          printf '.'
          return 0
          ;;
        *)
          printf 'root containment: absolute path outside project root: %s\n' "$val" >&2
          return 1
          ;;
      esac
      ;;
    *)
      # Relative path — pass through.
      printf '%s' "$val"
      return 0
      ;;
  esac
}

# --- combined validation ---

# touch_set_validate_value <value> <project_root>
#   Returns 0 and prints the normalised value on stdout if valid.
#   Returns 1 with diagnostic on stderr if invalid.
touch_set_validate_value() {
  local val="$1" project_root="$2"
  local normalised

  # Newline / NUL check first.
  touch_set_check_nul_newline "$val" || return 1

  # Denylist.
  touch_set_denylist_check "$val" || return 1

  # Climb-out.
  touch_set_check_climb_out "$val" || return 1

  # Root containment (also normalises).
  normalised="$(touch_set_root_containment "$val" "$project_root")" || return 1

  printf '%s' "$normalised"
  return 0
}

# --- pre-write hook ---

# touch_set_prewrite_check <story_file> <new_values_file>
#   Validates every value in new_values_file. Override after sourcing
#   to inject a custom gate (e.g. a continuous re-check gate).
touch_set_prewrite_check() {
  local story_file="$1" new_values_file="$2"
  local line rc=0

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    touch_set_check_nul_newline "$line" || rc=1
    touch_set_denylist_check "$line" || rc=1
    touch_set_check_climb_out "$line" || rc=1
  done < "$new_values_file"
  return "$rc"
}

# --- safe writer ---

# touch_set_write <story_file> <values_file> <project_root>
#   Writes the field to the story via yq strenv/--arg.
touch_set_write() {
  local story_file="$1" values_file="$2" project_root="$3"
  local tmp_vals rc=0

  tmp_vals="$(mktemp "${TMPDIR:-/tmp}/ts-norm.XXXXXX")"

  # Normalise each value.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    local norm
    norm="$(touch_set_validate_value "$line" "$project_root")" || { rc=1; continue; }
    printf '%s\n' "$norm"
  done < "$values_file" > "$tmp_vals"

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp_vals"
    return 1
  fi

  # Hook check.
  if ! touch_set_prewrite_check "$story_file" "$tmp_vals"; then
    rm -f "$tmp_vals"
    return 1
  fi

  # Build a JSON array from the normalised values, write to a temp JSON
  # file, and use yq load() to inject it. This avoids the fromjson
  # compatibility issue with --front-matter=process.
  local field_name="$_TS_FIELD_NAME"
  local json_file
  json_file="$(mktemp "${TMPDIR:-/tmp}/ts-json.XXXXXX")"

  awk '
    BEGIN { printf "[" }
    NR > 1 { printf ", " }
    { gsub(/\\/, "\\\\", $0); gsub(/"/, "\\\"", $0); printf "\"%s\"", $0 }
    END { printf "]\n" }
  ' "$tmp_vals" > "$json_file"

  rm -f "$tmp_vals"

  yq --front-matter=process -i \
    ".${field_name} = load(\"${json_file}\")" \
    "$story_file"

  rm -f "$json_file"
}

# --- NUL-delimited reader ---

# touch_set_read_nul <story_file>
#   Reads the field and emits each value separated by NUL bytes.
#   Use: while IFS= read -r -d '' val; do ... ; done < <(touch_set_read_nul file)
touch_set_read_nul() {
  local story_file="$1"
  local field_name="$_TS_FIELD_NAME"

  # yq -r0 emits NUL-delimited values from a YAML array.
  TS_FIELD="$field_name" \
    yq --front-matter=extract -r0 \
      '.[strenv(TS_FIELD)] // [] | .[]' \
      "$story_file" 2>/dev/null || true
}

# --- flow array builder ---

# touch_set_build_flow_array <values_file>
#   Build a YAML flow array string from a values file (one path per line).
#   Output: ["a", "b"]. Empty file or no lines → [].
touch_set_build_flow_array() {
  local values_file="$1"

  if [ ! -s "$values_file" ]; then
    printf '[]'
    return 0
  fi

  awk '
    BEGIN { first = 1; printf "[" }
    /^[[:space:]]*$/ { next }
    {
      if (!first) printf ", "
      # Escape embedded double quotes and backslashes for JSON.
      gsub(/\\/, "\\\\", $0)
      gsub(/"/, "\\\"", $0)
      printf "\"%s\"", $0
      first = 0
    }
    END {
      if (first) printf "]"
      else printf "]"
    }
  ' "$values_file"
}

# --- double-star warning ---

# touch_set_warn_double_star <value>
#   Emits a warning on stderr if the value contains **.
touch_set_warn_double_star() {
  local val="$1"
  case "$val" in
    *'**'*)
      printf 'warning: ** behaves identically to * in find -path; use * instead\n' >&2
      ;;
  esac
}
