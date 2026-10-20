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

# ---------------------------------------------------------------------------
# _catch_all_write_inline_marker <epics_file> <epic_key> <value>
#   Write/update the inline catch_all marker under the epic heading.
#   Uses mktemp + mv for atomic writes.
# ---------------------------------------------------------------------------
_catch_all_write_inline_marker() {
  local epics_file="$1" epic_key="$2" value="$3"
  local epic_num="${epic_key#E}"
  local new_marker="<!-- catch_all: ${value} -->"
  local old_marker_true="<!-- catch_all: true -->"
  local old_marker_false="<!-- catch_all: false -->"
  local tmp_file
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/caf-inline.XXXXXX")"

  awk -v ekey="$epic_key" -v enum="$epic_num" -v marker="$new_marker" \
      -v old_t="$old_marker_true" -v old_f="$old_marker_false" '
    BEGIN { looking=0; wrote=0 }
    /^## / {
      if (looking && !wrote) { print marker; wrote=1 }
      looking=0
      if (index($0, "E" enum " ") > 0 || \
          ($0 ~ "Epic " enum ":") || \
          ($0 ~ "Epic E" enum " ")) {
        looking=1; wrote=0
      }
      print; next
    }
    looking && ($0 == old_t || $0 == old_f) {
      print marker; wrote=1; looking=0; next
    }
    looking && /^[[:space:]]*$/ { print; next }
    looking && !/^[[:space:]]*$/ {
      if (!wrote) { print marker; wrote=1 }
      looking=0; print; next
    }
    { print }
    END { if (looking && !wrote) print marker }
  ' "$epics_file" > "$tmp_file"

  mv -f "$tmp_file" "$epics_file"
}

# ---------------------------------------------------------------------------
# _catch_all_set_unset <mode> <epic_key> <epics_file> <shards_dir>
#   mode = "set" (true) or "unset" (false).
#   Runs independence re-check, writes the flag, appends audit trail.
# ---------------------------------------------------------------------------
_catch_all_set_unset() {
  local mode="$1" epic_key="$2" epics_file="$3" shards_dir="${4:-}"
  local new_val old_val
  case "$mode" in
    set)   new_val="true" ;;
    unset) new_val="false" ;;
    *) printf 'catch-all-flag.sh: invalid mode: %s\n' "$mode" >&2; return 2 ;;
  esac

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local project_root="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"
  local gaia_dir=".gaia"
  local state_dir="${project_root%/}/${gaia_dir}/state"
  local audit_log="${state_dir}/catch-all-audit.log"
  local audit_snapshot="${state_dir}/catch-all-audit.snapshot"
  mkdir -p "$state_dir"

  # Determine current value.
  local current_val="false"
  local current_set
  current_set="$(catch_all_epics "$epics_file" "$shards_dir" 2>/dev/null)" || true
  if printf '%s\n' "$current_set" | /usr/bin/grep -Fqx "$epic_key" 2>/dev/null; then
    current_val="true"
  fi

  if [ "$current_val" = "$new_val" ]; then
    printf 'catch-all-flag.sh: %s already has catch_all=%s\n' \
      "$epic_key" "$new_val"
    return 0
  fi

  # Run independence re-check as pre-mutation gate.
  # Strategy: apply the flag change to the epics file, run the independence
  # check against the post-change state, then revert if the check fails.
  # This ensures rule (b) is evaluated with the new flag value.
  local gate_result="pass"
  local ic_script="${script_dir}/../independence-check.sh"

  if [ -x "$ic_script" ]; then
    # Find the first active sprint (any one will do for the check).
    local first_sprint=""
    local f
    for f in "${state_dir}"/sprint-status-*.yaml; do
      [ -f "$f" ] || continue
      case "$f" in *.lock|*.result) continue ;; esac
      local st=""
      st="$(awk '/^status:[[:space:]]*/ {
          v=$0; sub(/^status:[[:space:]]*/, "", v)
          gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
          print v; exit
        }' "$f" 2>/dev/null)" || continue
      [ "$st" = "active" ] || continue
      local sid=""
      sid="$(awk '/^sprint_id:[[:space:]]*/ {
          v=$0; sub(/^sprint_id:[[:space:]]*/, "", v)
          gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
          print v; exit
        }' "$f" 2>/dev/null)" || continue
      if [ -z "$first_sprint" ]; then
        first_sprint="$sid"
      fi
    done

    if [ -n "$first_sprint" ]; then
      # Back up the epics file, apply the change, check, then revert on failure.
      local epics_backup
      epics_backup="$(mktemp "${TMPDIR:-/tmp}/caf-bak.XXXXXX")"
      cp "$epics_file" "$epics_backup"

      # Apply the flag change to the real file (pre-check).
      _catch_all_write_inline_marker "$epics_file" "$epic_key" "$new_val"

      local check_rc=0
      bash "$ic_script" --candidate "$first_sprint" 2>/dev/null || check_rc=$?
      if [ "$check_rc" -ne 0 ]; then
        gate_result="fail"
        # Revert the epics file.
        mv -f "$epics_backup" "$epics_file"
      else
        rm -f "$epics_backup"
      fi
    fi
  fi

  # Record timestamp.
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Append audit trail entry.
  printf '%s %s catch_all=%s->%s actor=catch-all-flag.sh result=%s\n' \
    "$timestamp" "$epic_key" "$current_val" "$new_val" "$gate_result" \
    >> "$audit_log"

  if [ "$gate_result" = "fail" ]; then
    printf 'catch-all-flag.sh: independence re-check failed — change blocked\n' >&2
    return 1
  fi

  # Apply the flag change.
  local epic_num="${epic_key#E}"
  local shard_has_field=0

  if [ -n "$shards_dir" ] && [ -d "$shards_dir" ]; then
    local sf base base_lower snum
    for sf in "$shards_dir"/*; do
      [ -f "$sf" ] || continue
      base="${sf##*/}"
      base_lower="$(printf '%s' "$base" | LC_ALL=C tr 'A-Z' 'a-z')"
      case "$base_lower" in
        [0-9]*-e[0-9]*-*)
          snum="${base_lower#*-e}"
          snum="${snum%%-*}"
          if [ "$snum" = "$epic_num" ]; then
            if /usr/bin/grep -q 'catch_all:' "$sf" 2>/dev/null; then
              shard_has_field=1
              local tmp_shard
              tmp_shard="$(mktemp "${TMPDIR:-/tmp}/caf-shard.XXXXXX")"
              awk -v val="$new_val" '
                BEGIN { in_fm=0; s=0; w=0 }
                /^---[[:space:]]*$/ {
                  if (!s) { s=1; in_fm=1 } else { if (!w) print "catch_all: " val; in_fm=0 }
                  print; next
                }
                in_fm && /^catch_all:/ { print "catch_all: " val; w=1; next }
                { print }
              ' "$sf" > "$tmp_shard"
              mv -f "$tmp_shard" "$sf"
            fi
            break
          fi
          ;;
      esac
    done
  fi

  if [ "$shard_has_field" -eq 0 ]; then
    _catch_all_write_inline_marker "$epics_file" "$epic_key" "$new_val"
  fi

  # Rewrite the audit snapshot.
  _CATCH_ALL_AUDIT_MODE=1 catch_all_epics "$epics_file" "$shards_dir" \
    > "$audit_snapshot" 2>/dev/null || true

  # Run --audit to show advisory.
  _CATCH_ALL_AUDIT_MODE=1 catch_all_epics "$epics_file" "$shards_dir" \
    >/dev/null 2>&1 || true

  printf 'catch-all-flag.sh: %s catch_all=%s->%s applied\n' \
    "$epic_key" "$current_val" "$new_val"
  return 0
}

main() {
  local epics_file="" shards_dir="" audit=0
  local set_epic="" unset_epic=""
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
      --set)
        set_epic="${2:-}"; shift 2 || { _catch_all_flag_usage >&2; return 2; }
        ;;
      --unset)
        unset_epic="${2:-}"; shift 2 || { _catch_all_flag_usage >&2; return 2; }
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

  # Set/unset mode.
  if [ -n "$set_epic" ]; then
    _catch_all_set_unset "set" "$set_epic" "$epics_file" "$shards_dir"
    return $?
  fi
  if [ -n "$unset_epic" ]; then
    _catch_all_set_unset "unset" "$unset_epic" "$epics_file" "$shards_dir"
    return $?
  fi

  _CATCH_ALL_AUDIT_MODE="$audit" catch_all_epics "$epics_file" "$shards_dir"
}

# Sourceable + runnable dual-mode guard.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
