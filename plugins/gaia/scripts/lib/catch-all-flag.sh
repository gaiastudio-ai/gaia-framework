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
# Precedence:
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
# Performance:
#   A single awk pass extracts heading+marker pairs from the epics file.
#   A single awk pass reads all shard frontmatter catch_all values.
#   Shell processing touches only extracted pairs (typically < 200 lines
#   from a 39k-line file). Target: < 2 s on the real project file.
#
# POSIX discipline: bash 3.2 compatible (macOS default). set -euo pipefail.
# BRE patterns use [0-9][0-9]* (not \+) for BSD sed compatibility.

set -euo pipefail
LC_ALL=C
export LC_ALL

# Em-dash constant (U+2014, three UTF-8 bytes: 0xe2 0x80 0x94).
_CATCH_ALL_EMDASH=$'\xe2\x80\x94'
# Field separator and empty-field placeholder for the heading-pairs format.
# Tab-delimited with "_NONE_" for empty marker fields (avoids consecutive
# tab collapsing in bash read which drops empty fields).
_CATCH_ALL_EMPTY_MARKER="_NONE_"

# ---------------------------------------------------------------------------
# _extract_heading_pairs <epics_file>
#
# Single-pass awk that emits one record per epic heading found, in the form:
#   KEY<TAB>TITLE<TAB>MARKER<TAB>RECOGNIZED
# where MARKER is the first non-blank line after the heading (or empty),
# and RECOGNIZED is "1" for a known heading form, "0" for an unrecognized
# H2 that looks epic-like. This avoids per-line forks.
_extract_heading_pairs() {
  local epics_file="$1"
  local emdash_sep=" ${_CATCH_ALL_EMDASH} "
  local empty_marker="$_CATCH_ALL_EMPTY_MARKER"
  LC_ALL=C awk -v sep="$emdash_sep" -v none="$empty_marker" '
    BEGIN { key=""; title=""; recognized=0; looking=0; seplen=length(sep) }

    function flush() {
      if (looking && key != "") {
        t = (title == "") ? none : title
        printf "%s\t%s\t%s\t%s\n", key, t, none, recognized
      }
    }

    # Form (a): ## E{N} — Title
    /^## E[0-9]/ && index($0, sep) > 0 && substr($0, 1, 9) != "## Epic " {
      s = substr($0, 4)
      idx = index(s, sep)
      if (idx > 0) {
        cand = substr(s, 1, idx - 1)
        if (cand ~ /^E[0-9]+$/) {
          flush()
          key = cand; title = substr(s, idx + seplen)
          recognized = 1; looking = 1; next
        }
      }
    }

    # Form (b): ## Epic {N}: Title  ("## Epic " = 8 chars, number at pos 9)
    /^## Epic [0-9]/ && index($0, ": ") > 0 {
      s = substr($0, 9)
      idx = index(s, ": ")
      if (idx > 0) {
        num = substr(s, 1, idx - 1)
        if (num ~ /^[0-9]+$/) {
          flush()
          key = "E" num; title = substr(s, idx + 2)
          recognized = 1; looking = 1; next
        }
      }
    }

    # Form (c): ## Epic E{N} -- Title  ("## Epic " = 8 chars, key at pos 9)
    /^## Epic E[0-9]/ && index($0, " -- ") > 0 {
      s = substr($0, 9)
      idx = index(s, " -- ")
      if (idx > 0) {
        cand = substr(s, 1, idx - 1)
        if (cand ~ /^E[0-9]+$/) {
          flush()
          key = cand; title = substr(s, idx + 4)
          recognized = 1; looking = 1; next
        }
      }
    }

    # Form (d): ## Epic E{N} — Title  ("## Epic " = 8 chars, key at pos 9)
    /^## Epic E[0-9]/ && index($0, sep) > 0 {
      s = substr($0, 9)
      idx = index(s, sep)
      if (idx > 0) {
        cand = substr(s, 1, idx - 1)
        if (cand ~ /^E[0-9]+$/) {
          flush()
          key = cand; title = substr(s, idx + seplen)
          recognized = 1; looking = 1; next
        }
      }
    }

    # Unrecognized H2 that looks epic-like (has E followed by digits)
    /^## E[0-9]/ {
      flush()
      key = "?"; title = ""; recognized = 0; looking = 1; next
    }

    # Any other H2 resets state
    /^## / {
      flush()
      key = ""; title = ""; looking = 0; next
    }

    # When looking for the marker: skip blank lines, capture first non-blank
    looking == 1 && /^[[:space:]]*$/ { next }
    looking == 1 {
      t = (title == "") ? none : title
      printf "%s\t%s\t%s\t%s\n", key, t, $0, recognized
      looking = 0; next
    }

    END { flush() }
  ' "$epics_file"
}

# ---------------------------------------------------------------------------
# _batch_read_shard_flags <shards_dir>
#
# Batch-reads catch_all values from ALL shard frontmatter files in one pass.
# Outputs: EPIC_NUM<TAB>VALUE lines (value is "true" or "false").
# Also outputs EPIC_NUM<TAB>MULTI for duplicate shard matches (stderr gets paths).
_batch_read_shard_flags() {
  local shards_dir="$1"
  [ -n "$shards_dir" ] && [ -d "$shards_dir" ] || return 0

  # Build a list of shard files with their epic numbers.
  # Use a single awk invocation across all files: awk processes FILENAME
  # to extract the epic number and reads frontmatter for catch_all.
  # shellcheck disable=SC2086
  set -- "$shards_dir"/*
  # If glob matched nothing, $1 is the literal pattern.
  [ -f "$1" ] || return 0

  # Single pass: map shard files to epic numbers, read frontmatter, detect dupes.
  # Collect results; emit only after duplicate detection.
  local seen_nums=""  # " num " entries for seen-check
  local dup_nums=""   # " num " entries for duplicates
  local results=""    # accumulated "num\tval\n" lines
  local f base base_lower shard_num
  for f in "$@"; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    base_lower="$(printf '%s' "$base" | LC_ALL=C tr 'A-Z' 'a-z')"
    shard_num=""
    case "$base_lower" in
      [0-9]*-e[0-9]*-*)
        shard_num="${base_lower#*-e}"
        shard_num="${shard_num%%-*}"
        ;;
    esac
    [ -n "$shard_num" ] || continue

    # Duplicate check.
    case "$seen_nums" in
      *" ${shard_num} "*)
        case "$dup_nums" in
          *" ${shard_num} "*) ;;
          *) dup_nums="${dup_nums} ${shard_num} "
             printf 'catch-all-flag.sh: multiple shard files match epic E%s (fail closed)\n' "$shard_num" >&2 ;;
        esac
        continue ;;
    esac
    seen_nums="${seen_nums} ${shard_num} "

    # Read frontmatter catch_all (shard files are small, ~50 lines each).
    local val
    val="$(LC_ALL=C awk '
      NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
      fm && /^---[[:space:]]*$/ { exit }
      fm { line = tolower($0)
        if (line ~ /^catch_all:/) {
          sub(/^[^:]*:[[:space:]]*/, "", line)
          if (line == "true") { print "true"; exit }
          if (line == "false") { print "false"; exit }
        }
        next
      }
      !fm { exit }
    ' "$f")"

    if [ -n "$val" ]; then
      results="${results}${shard_num}	${val}
"
    fi
  done

  # Emit results, excluding duplicates.
  if [ -n "$results" ]; then
    while IFS=$'\t' read -r num val; do
      [ -n "$num" ] || continue
      case "$dup_nums" in
        *" ${num} "*)
          printf '%s\tMULTI\n' "$num"
          ;;
        *)
          printf '%s\t%s\n' "$num" "$val"
          ;;
      esac
    done <<< "$results"
  fi
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

  # Case-insensitive match using case-folded case statement (no forks).
  local lower_title
  lower_title="$(printf '%s' "$epic_title" | LC_ALL=C tr 'A-Z' 'a-z')"
  case "$lower_title" in
    *bug*|*enhancement*|*fix*|*maintenance*|*catch-all*|*backlog*|*misc*)
      return 0 ;;
  esac

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

  # Phase 1: single-pass awk extracts heading+marker pairs from epics file.
  local pairs
  pairs="$(_extract_heading_pairs "$epics_file")"

  # Phase 2: batch-read all shard catch_all values.
  local shard_flags=""
  if [ -n "$shards_dir" ] && [ -d "$shards_dir" ]; then
    shard_flags="$(_batch_read_shard_flags "$shards_dir" 2>&1)"
  fi

  # Phase 3: process extracted pairs with shard overrides.
  local emitted_keys=""
  local empty_marker="$_CATCH_ALL_EMPTY_MARKER"
  while IFS=$'\t' read -r key title marker recognized; do
    [ -n "$key" ] || continue
    # Replace the empty-field placeholders with actual empty strings.
    [ "$title" = "$empty_marker" ] && title=""
    [ "$marker" = "$empty_marker" ] && marker=""

    # Unrecognized heading form with a marker below it.
    if [ "$recognized" = "0" ] && [ -n "$marker" ]; then
      case "$marker" in
        '<!-- catch_all: true -->'|'<!-- catch_all: false -->')
          printf 'catch-all-flag.sh: catch_all marker found under unrecognized heading form (marker not applied): %s\n' \
            "$marker" >&2
          ;;
      esac
      continue
    fi

    # Skip unrecognized headings without markers.
    [ "$recognized" = "1" ] || continue

    # Determine inline marker value.
    local inline_val=""
    case "$marker" in
      '<!-- catch_all: true -->') inline_val="true" ;;
      '<!-- catch_all: false -->') inline_val="false" ;;
    esac

    # No inline marker — skip (may be picked up by shard-only pass below).
    [ -n "$inline_val" ] || continue

    # Look up shard value from the batch results.
    local epic_num="${key#E}"
    local shard_val=""
    if [ -n "$shard_flags" ]; then
      local shard_line
      shard_line="$(printf '%s\n' "$shard_flags" | LC_ALL=C awk -F'\t' -v n="$epic_num" '$1 == n { print $2; exit }')"
      if [ "$shard_line" = "MULTI" ]; then
        printf 'catch-all-flag.sh: multiple shard files match epic %s (fail closed)\n' "$key" >&2
        continue
      fi
      shard_val="$shard_line"
    fi

    if [ -n "$shard_val" ]; then
      if [ "$shard_val" != "$inline_val" ]; then
        printf 'catch-all-flag.sh: warning: epic %s has conflicting catch_all values (inline=%s, shard=%s); shard overrides\n' \
          "$key" "$inline_val" "$shard_val" >&2
      fi
      if [ "$shard_val" = "true" ]; then
        [ "$audit_mode" = "1" ] && _catch_all_audit_advisory "$key" "$title"
        printf '%s\n' "$key"
        emitted_keys="${emitted_keys} ${key} "
      fi
    else
      if [ "$inline_val" = "true" ]; then
        [ "$audit_mode" = "1" ] && _catch_all_audit_advisory "$key" "$title"
        printf '%s\n' "$key"
        emitted_keys="${emitted_keys} ${key} "
      fi
    fi
  done <<< "$pairs"

  # Phase 4: check for epics flagged only via shard frontmatter (no inline marker).
  if [ -n "$shard_flags" ]; then
    while IFS=$'\t' read -r shard_num shard_val; do
      [ -n "$shard_num" ] || continue
      [ "$shard_val" = "true" ] || continue
      local shard_key="E${shard_num}"

      # Skip if already emitted from inline parsing.
      case "$emitted_keys" in
        *" ${shard_key} "*) continue ;;
      esac

      # Shard-only flag. Get the title for audit advisory from the pairs.
      if [ "$audit_mode" = "1" ]; then
        local stitle=""
        stitle="$(printf '%s\n' "$pairs" | LC_ALL=C awk -F'\t' -v k="$shard_key" '$1 == k { print $2; exit }')"
        [ -n "$stitle" ] && _catch_all_audit_advisory "$shard_key" "$stitle"
      fi
      printf '%s\n' "$shard_key"
    done <<< "$shard_flags"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# is_catch_all <epic_key> <epics_file> [<shards_dir>]
#
# Convenience reader for a single epic. Returns 0 (true) if the epic is
# in the catch-all set, 1 (false) otherwise. Suitable for `if is_catch_all ...`.
# This is the stable reader interface for consumers like the independence check.
#
# Performance: when called repeatedly for different keys on the same file,
# pass a precomputed set via _CATCH_ALL_SET to avoid re-parsing. The
# independence check should compute the set once with catch_all_epics and
# test membership with a simple grep -Fqx on the result.
is_catch_all() {
  local epic_key="${1:-}"
  local epics_file="${2:-}"
  local shards_dir="${3:-}"

  if [ -z "$epic_key" ] || [ -z "$epics_file" ]; then
    return 1
  fi

  # Use precomputed set if available (one set per file, caller's responsibility).
  local result="${_CATCH_ALL_SET:-}"
  if [ -z "$result" ]; then
    result="$(catch_all_epics "$epics_file" "$shards_dir" 2>/dev/null)" || return 1
  fi

  printf '%s\n' "$result" | LC_ALL=C grep -Fqx "$epic_key"
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
