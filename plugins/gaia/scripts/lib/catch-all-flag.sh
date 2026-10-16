#!/usr/bin/env bash
# catch-all-flag.sh — Catch-all epic flag parser
#
# Determines which epics are explicitly flagged as catch-all.
# Catch-all epics may appear in multiple concurrent sprints without
# violating the shared-epic independence rule.
#
# The flag is EXPLICIT — never inferred from epic name, size, or content.
#
# Sources:
#   1. Inline marker in epics-and-stories.md:
#      A standalone `<!-- catch_all: true -->` line as the first non-blank
#      line below an epic heading.
#   2. Shard frontmatter at .../epics/*-e{n}-*.md:
#      A `catch_all: true` YAML frontmatter field.
#
# Precedence (per D-S6-1):
#   When both sources contain an explicit `catch_all:` field and disagree,
#   the shard value overrides and a warning is emitted. When the shard
#   field is absent (or the shard file is missing), the inline marker
#   applies silently.
#
# Modes:
#   SOURCED — exposes catch_all_epics <epics_file> [<shards_dir>] function.
#             Sourcing this file produces zero stdout, zero stderr, and does
#             NOT auto-execute main.
#   CLI     — runs main "$@" when invoked as a script.
#             Flags: --epics-file <path>, --shards-dir <path>, --audit, -h|--help.
#             Exit codes: 0 success, 1 missing/unreadable epics file, 2 usage error.
#
# POSIX discipline: bash 3.2 compatible (macOS default). set -euo pipefail.
# BRE patterns use [0-9][0-9]* (not \+) for BSD sed compatibility.

set -euo pipefail
LC_ALL=C
export LC_ALL

# Em-dash constant (U+2014, three UTF-8 bytes: 0xe2 0x80 0x94).
# Stored in a variable to avoid $'...' inside grep/sed pattern strings,
# which interact poorly with bash 3.2 + BSD sed.
_CATCH_ALL_EMDASH=$'\xe2\x80\x94'

# ---------------------------------------------------------------------------
# Recognized heading patterns (same four forms as resolve-epic-slug.sh):
#   (a) ## E{N} — Title            (em-dash U+2014)
#   (b) ## Epic {N}: Title         (natural-language)
#   (c) ## Epic E{N} -- Title      (ASCII double-hyphen with Epic prefix)
#   (d) ## Epic E{N} — Title       (em-dash with Epic prefix)
#
# _parse_heading_epic_key <line>
#   If the line is a recognized epic heading, prints the epic key (e.g. E28)
#   to stdout and returns 0. Otherwise returns 1.
_parse_heading_epic_key() {
  local line="$1"
  local key=""

  # Form (a): ## E{N} — Title
  if printf '%s' "$line" | LC_ALL=C grep -q "^## E[0-9][0-9]* ${_CATCH_ALL_EMDASH} "; then
    key="$(printf '%s' "$line" | LC_ALL=C sed "s/^## \(E[0-9][0-9]*\) ${_CATCH_ALL_EMDASH} .*/\1/")"
    printf '%s\n' "$key"
    return 0
  fi

  # Form (b): ## Epic {N}: Title
  if printf '%s' "$line" | LC_ALL=C grep -q '^## Epic [0-9][0-9]*: '; then
    local num
    num="$(printf '%s' "$line" | LC_ALL=C sed 's/^## Epic \([0-9][0-9]*\): .*/\1/')"
    printf 'E%s\n' "$num"
    return 0
  fi

  # Form (c): ## Epic E{N} -- Title
  if printf '%s' "$line" | LC_ALL=C grep -q '^## Epic E[0-9][0-9]* -- '; then
    key="$(printf '%s' "$line" | LC_ALL=C sed 's/^## Epic \(E[0-9][0-9]*\) -- .*/\1/')"
    printf '%s\n' "$key"
    return 0
  fi

  # Form (d): ## Epic E{N} — Title
  if printf '%s' "$line" | LC_ALL=C grep -q "^## Epic E[0-9][0-9]* ${_CATCH_ALL_EMDASH} "; then
    key="$(printf '%s' "$line" | LC_ALL=C sed "s/^## Epic \(E[0-9][0-9]*\) ${_CATCH_ALL_EMDASH} .*/\1/")"
    printf '%s\n' "$key"
    return 0
  fi

  return 1
}

# _extract_heading_title <line>
#   Extracts the title portion from a recognized heading.
_extract_heading_title() {
  local line="$1"

  # Form (a)
  if printf '%s' "$line" | LC_ALL=C grep -q "^## E[0-9][0-9]* ${_CATCH_ALL_EMDASH} "; then
    printf '%s' "$line" | LC_ALL=C sed "s/^## E[0-9][0-9]* ${_CATCH_ALL_EMDASH} //"
    return 0
  fi
  # Form (b)
  if printf '%s' "$line" | LC_ALL=C grep -q '^## Epic [0-9][0-9]*: '; then
    printf '%s' "$line" | LC_ALL=C sed 's/^## Epic [0-9][0-9]*: //'
    return 0
  fi
  # Form (c)
  if printf '%s' "$line" | LC_ALL=C grep -q '^## Epic E[0-9][0-9]* -- '; then
    printf '%s' "$line" | LC_ALL=C sed 's/^## Epic E[0-9][0-9]* -- //'
    return 0
  fi
  # Form (d)
  if printf '%s' "$line" | LC_ALL=C grep -q "^## Epic E[0-9][0-9]* ${_CATCH_ALL_EMDASH} "; then
    printf '%s' "$line" | LC_ALL=C sed "s/^## Epic E[0-9][0-9]* ${_CATCH_ALL_EMDASH} //"
    return 0
  fi
  return 1
}

# _is_catch_all_marker <line>
#   Returns 0 if the line is a standalone catch_all marker (true or false).
#   Prints "true" or "false" to stdout when matched.
_is_catch_all_marker() {
  local line="$1"
  # Match <!-- catch_all: true --> or <!-- catch_all: false -->
  # Case-sensitive on the HTML comment body as specified.
  if printf '%s' "$line" | LC_ALL=C grep -q '^<!-- catch_all: true -->$'; then
    printf 'true\n'
    return 0
  fi
  if printf '%s' "$line" | LC_ALL=C grep -q '^<!-- catch_all: false -->$'; then
    printf 'false\n'
    return 0
  fi
  return 1
}

# _read_shard_catch_all <shards_dir> <epic_key>
#   Reads the catch_all field from shard frontmatter.
#   Prints "true", "false", or "" (absent) to stdout.
#   Returns 0 on success, 1 on multiple shard matches (error on stderr).
_read_shard_catch_all() {
  local shards_dir="$1"
  local epic_key="$2"
  local epic_num="${epic_key#E}"

  if [ -z "$shards_dir" ] || [ ! -d "$shards_dir" ]; then
    # No shards directory — silent, inline marker applies.
    printf '\n'
    return 0
  fi

  # Match pattern: anchored ^[0-9]+-e{n}- (case-insensitive on epic number)
  local matches=""
  local match_count=0
  local f
  for f in "$shards_dir"/*; do
    [ -f "$f" ] || continue
    local base
    base="$(basename "$f")"
    # Anchored pattern: starts with digits, then -e{N}- (case-insensitive)
    if printf '%s' "$base" | LC_ALL=C grep -qi "^[0-9][0-9]*-e${epic_num}-"; then
      matches="${matches:+${matches}
}${f}"
      match_count=$((match_count + 1))
    fi
  done

  if [ "$match_count" -eq 0 ]; then
    printf '\n'
    return 0
  fi

  if [ "$match_count" -gt 1 ]; then
    printf 'catch-all-flag.sh: multiple shard files match epic %s (fail closed):\n' "$epic_key" >&2
    printf '%s\n' "$matches" >&2
    printf '\n'
    return 1
  fi

  local shard_file
  shard_file="$(printf '%s' "$matches" | head -1)"

  # Read frontmatter — look for catch_all field in YAML between --- markers.
  local in_frontmatter=0
  local found_opening=0
  local value=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$found_opening" -eq 0 ]; then
      if printf '%s' "$line" | LC_ALL=C grep -q '^---[[:space:]]*$'; then
        found_opening=1
        in_frontmatter=1
        continue
      else
        # No frontmatter block — silent.
        break
      fi
    fi
    if [ "$in_frontmatter" -eq 1 ]; then
      if printf '%s' "$line" | LC_ALL=C grep -q '^---[[:space:]]*$'; then
        # End of frontmatter.
        break
      fi
      # Look for catch_all: field (YAML booleans are case-insensitive)
      if printf '%s' "$line" | LC_ALL=C grep -qi '^catch_all:[[:space:]]'; then
        local raw_val
        raw_val="$(printf '%s' "$line" | LC_ALL=C sed 's/^catch_all:[[:space:]]*//' | LC_ALL=C tr 'A-Z' 'a-z')"
        if [ "$raw_val" = "true" ]; then
          value="true"
        elif [ "$raw_val" = "false" ]; then
          value="false"
        fi
        # Other values are treated as absent.
      fi
    fi
  done < "$shard_file"

  printf '%s\n' "$value"
  return 0
}

# ---------------------------------------------------------------------------
# _catch_all_audit_advisory <epic_key> <epic_title>
#
# Advisory function for --audit mode ONLY. Emits a warning to stderr when
# a flagged epic's title does not match a bugs/enhancements-like pattern.
# This function only WARNS; it never sets or changes the catch-all flag.
# The AC2 no-inference source grep excludes this function body.
_catch_all_audit_advisory() {
  local epic_key="$1"
  local epic_title="$2"

  # Case-insensitive match against known catch-all-appropriate patterns
  if printf '%s' "$epic_title" | LC_ALL=C grep -qi 'bug\|enhancement\|fix\|maintenance\|catch-all\|backlog\|misc'; then
    # Title matches pattern — no advisory needed.
    return 0
  fi

  printf 'catch-all-flag.sh: advisory: epic %s ("%s") is flagged catch-all but its title does not match a typical catch-all pattern (bug|enhancement|fix|maintenance|catch-all|backlog|misc)\n' \
    "$epic_key" "$epic_title" >&2
}

# ---------------------------------------------------------------------------
# catch_all_epics <epics_file> [<shards_dir>]
#
# Prints one epic key per line on stdout for every epic explicitly flagged
# as catch-all. Warnings on stderr. Exit 0 on success, non-zero when the
# epics file is missing or unreadable. A read failure NEVER adds epics to
# the set.
#
# When <shards_dir> is omitted it is derived via resolve-config.sh.
catch_all_epics() {
  local epics_file="${1:-}"
  local shards_dir="${2:-}"
  local audit_mode="${_CATCH_ALL_AUDIT_MODE:-0}"

  if [ -z "$epics_file" ]; then
    printf 'catch-all-flag.sh: missing epics_file argument\n' >&2
    return 1
  fi

  if [ ! -f "$epics_file" ] || [ ! -r "$epics_file" ]; then
    printf 'catch-all-flag.sh: epics file missing or unreadable: %s\n' "$epics_file" >&2
    return 1
  fi

  # Derive shards_dir if not provided.
  if [ -z "$shards_dir" ]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local resolve_config="${script_dir}/../resolve-config.sh"
    if [ -x "$resolve_config" ]; then
      shards_dir="$("$resolve_config" planning_artifacts 2>/dev/null || true)/epics"
    fi
  fi

  # Track emitted keys to avoid duplicates in the shard-only pass.
  local emitted_keys=""

  # Parse epics-and-stories.md for epic headings and their catch_all markers.
  local current_epic_key=""
  local current_epic_title=""
  local looking_for_marker=0

  while IFS= read -r line || [ -n "$line" ]; do
    # Check if this is a recognized epic heading.
    local parsed_key=""
    parsed_key="$(_parse_heading_epic_key "$line" 2>/dev/null)" || true

    if [ -n "$parsed_key" ]; then
      # We found a new epic heading.
      current_epic_key="$parsed_key"
      current_epic_title="$(_extract_heading_title "$line" 2>/dev/null)" || true
      looking_for_marker=1
      continue
    fi

    # Check for unrecognized H2 that looks like an epic heading.
    if [ "$looking_for_marker" -eq 0 ]; then
      if printf '%s' "$line" | LC_ALL=C grep -q '^## '; then
        if printf '%s' "$line" | LC_ALL=C grep -q '^## E[0-9]'; then
          # Looks like an unrecognized epic heading form.
          current_epic_key=""
          current_epic_title=""
          looking_for_marker=2  # special: looking but unrecognized
          continue
        fi
        current_epic_key=""
        current_epic_title=""
        looking_for_marker=0
        continue
      fi
    fi

    if [ "$looking_for_marker" -ge 1 ]; then
      # Skip blank/whitespace-only lines — the marker is the first NON-blank
      # line after the heading. Use case to avoid a fork for empty lines.
      case "$line" in
        "") continue ;;
      esac
      if printf '%s\n' "$line" | LC_ALL=C grep -q '^[[:space:]]*$'; then
        continue
      fi

      # Check if this non-blank line is a catch_all marker.
      local marker_val=""
      marker_val="$(_is_catch_all_marker "$line")" || true

      if [ -n "$marker_val" ] && [ "$looking_for_marker" -eq 2 ]; then
        # Marker under an unrecognized heading — emit diagnostic, do not flag.
        printf 'catch-all-flag.sh: catch_all marker found under unrecognized heading form (marker not applied): %s\n' \
          "$line" >&2
        looking_for_marker=0
        current_epic_key=""
        current_epic_title=""
        continue
      fi

      if [ -n "$marker_val" ] && [ "$looking_for_marker" -eq 1 ] && [ -n "$current_epic_key" ]; then
        # We have an inline marker for a recognized heading.
        local inline_val="$marker_val"

        # Check shard frontmatter for override.
        local shard_val=""
        shard_val="$(_read_shard_catch_all "$shards_dir" "$current_epic_key")" || {
          # Multiple shard matches — fail closed: epic not flagged.
          looking_for_marker=0
          current_epic_key=""
          current_epic_title=""
          continue
        }

        if [ -n "$shard_val" ]; then
          # Both sources have an explicit value.
          if [ "$shard_val" != "$inline_val" ]; then
            printf 'catch-all-flag.sh: warning: epic %s has conflicting catch_all values (inline=%s, shard=%s); shard overrides\n' \
              "$current_epic_key" "$inline_val" "$shard_val" >&2
          fi
          # Shard overrides inline.
          if [ "$shard_val" = "true" ]; then
            if [ "$audit_mode" = "1" ]; then
              _catch_all_audit_advisory "$current_epic_key" "$current_epic_title"
            fi
            printf '%s\n' "$current_epic_key"
            emitted_keys="${emitted_keys} ${current_epic_key} "
          fi
        else
          # Shard is silent — inline applies.
          if [ "$inline_val" = "true" ]; then
            if [ "$audit_mode" = "1" ]; then
              _catch_all_audit_advisory "$current_epic_key" "$current_epic_title"
            fi
            printf '%s\n' "$current_epic_key"
            emitted_keys="${emitted_keys} ${current_epic_key} "
          fi
        fi
      fi

      # After the first non-blank line (whether marker or not), stop looking.
      looking_for_marker=0
    fi

  done < "$epics_file"

  # Also check for epics flagged only via shard frontmatter (no inline marker).
  if [ -n "$shards_dir" ] && [ -d "$shards_dir" ]; then
    local f
    for f in "$shards_dir"/*; do
      [ -f "$f" ] || continue
      local base
      base="$(basename "$f")"
      # Extract epic number from shard filename.
      local shard_num=""
      shard_num="$(printf '%s' "$base" | LC_ALL=C sed -n 's/^[0-9][0-9]*-[eE]\([0-9][0-9]*\)-.*/\1/p')"
      [ -n "$shard_num" ] || continue

      local shard_key="E${shard_num}"

      # Skip if already emitted from inline parsing.
      case "$emitted_keys" in
        *" ${shard_key} "*) continue ;;
      esac

      # Check if this shard has catch_all: true in frontmatter.
      local shard_val=""
      shard_val="$(_read_shard_catch_all "$shards_dir" "$shard_key" 2>/dev/null)" || continue
      [ "$shard_val" = "true" ] || continue

      # Shard-only flag. Get the title for audit advisory.
      if [ "$audit_mode" = "1" ]; then
        local title=""
        while IFS= read -r line || [ -n "$line" ]; do
          local pk=""
          pk="$(_parse_heading_epic_key "$line" 2>/dev/null)" || true
          if [ "$pk" = "$shard_key" ]; then
            title="$(_extract_heading_title "$line" 2>/dev/null)" || true
            break
          fi
        done < "$epics_file"
        if [ -n "$title" ]; then
          _catch_all_audit_advisory "$shard_key" "$title"
        fi
      fi
      printf '%s\n' "$shard_key"
    done
  fi

  return 0
}

# ---------------------------------------------------------------------------
# is_catch_all <epic_key> <epics_file> [<shards_dir>]
#
# Convenience reader for a single epic. Returns 0 (true) if the epic is
# in the catch-all set, 1 (false) otherwise. Suitable for `if is_catch_all ...`.
# This is the stable reader interface for consumers like the independence check.
is_catch_all() {
  local epic_key="${1:-}"
  local epics_file="${2:-}"
  local shards_dir="${3:-}"

  if [ -z "$epic_key" ] || [ -z "$epics_file" ]; then
    return 1
  fi

  local result
  result="$(catch_all_epics "$epics_file" "$shards_dir" 2>/dev/null)" || return 1

  printf '%s\n' "$result" | LC_ALL=C grep -qx "$epic_key"
}

# ---------------------------------------------------------------------------
# CLI front-end

_catch_all_flag_usage() {
  cat <<'USAGE'
Usage: catch-all-flag.sh --epics-file <path> [--shards-dir <path>] [--audit] [-h|--help]

Prints one catch-all epic key per line to stdout. Warnings on stderr.

Options:
  --epics-file <path>  Path to epics-and-stories.md. Required.
  --shards-dir <path>  Path to the per-epic shards directory. Optional;
                        derived from resolve-config.sh when omitted.
  --audit              Emit advisory warnings for flagged epics whose
                        title does not match a typical catch-all pattern.
  -h, --help           Print this usage and exit 0.

Exit codes:
  0  Success.
  1  Missing or unreadable epics file.
  2  Usage error.
USAGE
}

main() {
  local epics_file="" shards_dir="" audit=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --epics-file)
        epics_file="${2:-}"; shift 2 || { _catch_all_flag_usage >&2; return 2; }
        ;;
      --epics-file=*)
        epics_file="${1#--epics-file=}"; shift
        ;;
      --shards-dir)
        shards_dir="${2:-}"; shift 2 || { _catch_all_flag_usage >&2; return 2; }
        ;;
      --shards-dir=*)
        shards_dir="${1#--shards-dir=}"; shift
        ;;
      --audit)
        audit=1; shift
        ;;
      -h|--help)
        _catch_all_flag_usage
        return 0
        ;;
      *)
        printf 'catch-all-flag.sh: unknown argument: %s\n' "$1" >&2
        _catch_all_flag_usage >&2
        return 2
        ;;
    esac
  done

  if [ -z "$epics_file" ]; then
    printf 'catch-all-flag.sh: --epics-file is required\n' >&2
    _catch_all_flag_usage >&2
    return 2
  fi

  _CATCH_ALL_AUDIT_MODE="$audit" catch_all_epics "$epics_file" "$shards_dir"
}

# Sourceable + runnable dual-mode guard.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
