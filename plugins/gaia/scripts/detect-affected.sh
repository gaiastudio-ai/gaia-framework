#!/usr/bin/env bash
# detect-affected.sh — changed-path-to-owning-stack resolution
#
# Purpose:
#   Maps a list of changed-file paths (from git diff --name-only) to the stack
#   names declared in a project-config.yaml, using longest-prefix matching on
#   stacks[].path entries with a paths-glob fallback.
#
# Usage:
#   detect-affected.sh --config <project-config.yaml> \
#                      [--files-from <file-list.txt>] \
#                      [--files f1 f2 ...] \
#                      [--event <type>] \
#                      [--verbose] \
#                      [--help]
#
# Flags:
#   --config      Required. Path to project-config.yaml (must exist).
#   --files-from  Text file of newline-separated changed paths.
#   --files       Inline list of changed paths (can be combined with --files-from).
#   --event       Event type. When set to "promotion-push", outputs ["*"] immediately.
#   --verbose     Write per-path match decisions to stderr (never stdout).
#   --help        Print usage and exit 0.
#
# Output: a well-formed JSON array of matched stack names, deduplicated, on
#         stdout. Always exits 0 on success, 1 on caller error.
#
# Exit codes:
#   0 — success (may emit [] when no stacks match)
#   1 — caller error (missing --config, file not found, bad usage)
#
# Design notes:
#   - project-config.yaml globs carry a "gaia-public/" prefix (e.g.
#     "gaia-public/plugins/gaia/scripts/**").
#   - git diff --name-only returns paths WITHOUT that prefix (e.g.
#     "plugins/gaia/scripts/foo.sh").
#   - parse_stacks() strips "gaia-public/" and classifies each glob as either
#     a "prefix" match (glob ends with /**) or a "glob" match (all others).
#   - An optional scalar stacks[].path field is also parsed as match_type=prefix.
#   - find_best_prefix_match() implements longest-prefix-wins: all prefix-type
#     entries are iterated; the longest matching prefix takes precedence over a
#     shorter one regardless of declaration order. Ties break by declaration order.
#   - find_glob_match() falls back to bash [[ == ]] glob matching for non-prefix
#     entries (e.g., "config/*.yaml").
#   - promotion-push event early-returns ["*"] BEFORE reading any files.
#   - config/ subdir gap: stacks[].paths globs that do not end in /** are kept
#     as glob match_type to avoid over-generalising prefix matches. This also
#     means files under unlisted config/ subtrees return [] (known, advisory).
#
# POSIX awk compatibility: parse_stacks uses sub/gsub only (no gensub, no
# 3-arg match) to work with both macOS awk (BSD) and GNU awk.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# usage — print help to stdout and exit 0
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  detect-affected.sh --config <project-config.yaml> \
                     [--files-from <file-list.txt>] \
                     [--files f1 f2 ...] \
                     [--event <type>] \
                     [--verbose] \
                     [--help]

Options:
  --config PATH       Required. Path to project-config.yaml (must exist).
  --files-from PATH   Newline-separated file of changed paths.
  --files f1 f2 ...   Inline list of changed paths.
  --event TYPE        Event type; "promotion-push" forces output to ["*"].
  --verbose           Log per-path decisions to stderr.
  --help              Print this message and exit.

Exit codes:
  0  Success ([] emitted when nothing matches).
  1  Caller error (missing args, file not found).
USAGE
}

# ---------------------------------------------------------------------------
# parse_args — populate CONFIG, FILES_FROM, INLINE_FILES, EVENT, VERBOSE
# ---------------------------------------------------------------------------
parse_args() {
  CONFIG=""
  FILES_FROM=""
  INLINE_FILES=()
  EVENT=""
  VERBOSE=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG="$2"; shift 2 ;;
      --files-from)
        FILES_FROM="$2"; shift 2 ;;
      --files)
        shift
        while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
          INLINE_FILES+=("$1"); shift
        done ;;
      --event)
        EVENT="$2"; shift 2 ;;
      --verbose)
        VERBOSE=1; shift ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        printf 'detect-affected.sh: unknown option: %s\n' "$1" >&2
        exit 1 ;;
    esac
  done

  # promotion-push: early-return ["*"] before any config/file validation (AC4)
  if [[ "$EVENT" == "promotion-push" ]]; then
    printf '["*"]\n'
    exit 0
  fi

  if [[ -z "$CONFIG" ]]; then
    printf 'detect-affected.sh: --config is required\n' >&2
    exit 1
  fi
  if [[ ! -f "$CONFIG" ]]; then
    printf 'detect-affected.sh: config file not found: %s\n' "$CONFIG" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# parse_stacks — read stacks[].name + paths/path from YAML using POSIX awk.
#
# YAML shapes handled:
#
#   stacks:
#     - name: gaia-plugin
#       paths:
#         - "gaia-public/plugins/gaia/scripts/**"   → strip prefix + /**, type=prefix
#         - "gaia-public/config/*.yaml"              → strip prefix only, type=glob
#       path: "gaia-public/plugins/gaia"            → scalar path, type=prefix
#
# Output: one record per (stack_name, candidate, match_type) on stdout,
#         tab-separated: name<TAB>candidate<TAB>match_type
#
# match_type values:
#   prefix  — longest-prefix matching (/** glob or scalar path field)
#   glob    — bash glob matching (non-/** patterns like config/*.yaml)
#
# Uses POSIX awk only (sub/gsub/index) — no gensub, no 3-arg match.
# ---------------------------------------------------------------------------
parse_stacks() {
  local config="$1"
  awk '
  BEGIN {
    in_stacks = 0
    in_paths  = 0
    cur_name  = ""
  }

  # Enter the top-level stacks: block
  /^stacks:/ { in_stacks = 1; next }

  # Any top-level key (no leading whitespace) exits the stacks block
  in_stacks && /^[a-zA-Z_]/ { in_stacks = 0; in_paths = 0; cur_name = ""; next }

  # New stack entry: "  - name: <value>"
  in_stacks && /^[[:space:]]+-[[:space:]]+name:/ {
    cur_name = $0
    sub(/.*name:[[:space:]]*/, "", cur_name)
    gsub(/^[[:space:]]+/, "", cur_name)
    gsub(/[[:space:]]+$/, "", cur_name)
    gsub(/^"/, "",  cur_name); gsub(/"$/, "",  cur_name)
    gsub(/^'"'"'/, "", cur_name); gsub(/'"'"'$/, "", cur_name)
    in_paths = 0
    next
  }

  # Scalar path field: "    path: <value>" (single path, no trailing /**)
  in_stacks && cur_name != "" && /^[[:space:]]+path:[[:space:]]/ && !/^[[:space:]]+-/ {
    val = $0
    sub(/^[[:space:]]*path:[[:space:]]*/, "", val)
    gsub(/^[[:space:]]+/, "", val); gsub(/[[:space:]]+$/, "", val)
    gsub(/^"/, "", val); gsub(/"$/, "", val)
    gsub(/^'"'"'/, "", val); gsub(/'"'"'$/, "", val)
    # Strip leading gaia-public/
    sub(/^gaia-public\//, "", val)
    # Strip trailing /** if present, otherwise keep as-is — scalar path is prefix type
    if (val ~ /\/\*\*$/) { sub(/\/\*\*$/, "", val) }
    if (val != "") { print cur_name "\t" val "\tprefix" }
    next
  }

  # Enter the paths: list
  in_stacks && cur_name != "" && /^[[:space:]]+paths:[[:space:]]*$/ {
    in_paths = 1; next
  }

  # Path glob with double quotes
  in_stacks && in_paths && cur_name != "" && /^[[:space:]]+-[[:space:]]+"/ {
    glob = $0
    sub(/^[[:space:]]*-[[:space:]]*"/, "", glob)
    sub(/"[[:space:]]*$/, "", glob)
    if (glob == "") { next }
    # Strip leading gaia-public/
    sub(/^gaia-public\//, "", glob)
    # Classify: ends /** → prefix; else → glob
    if (glob ~ /\/\*\*$/) {
      sub(/\/\*\*$/, "", glob)
      print cur_name "\t" glob "\tprefix"
    } else {
      print cur_name "\t" glob "\tglob"
    }
    next
  }

  # Path glob with single quotes
  in_stacks && in_paths && cur_name != "" && /^[[:space:]]+-[[:space:]]+'"'"'/ {
    glob = $0
    sub(/^[[:space:]]*-[[:space:]]*'"'"'/, "", glob)
    sub(/'"'"'[[:space:]]*$/, "", glob)
    if (glob == "") { next }
    sub(/^gaia-public\//, "", glob)
    if (glob ~ /\/\*\*$/) {
      sub(/\/\*\*$/, "", glob)
      print cur_name "\t" glob "\tprefix"
    } else {
      print cur_name "\t" glob "\tglob"
    }
    next
  }

  # Path glob unquoted (bare value)
  in_stacks && in_paths && cur_name != "" && /^[[:space:]]+-[[:space:]]+[^'"'"'"[:space:]]/ {
    glob = $0
    sub(/^[[:space:]]*-[[:space:]]*/, "", glob)
    gsub(/[[:space:]]+$/, "", glob)
    if (glob == "") { next }
    sub(/^gaia-public\//, "", glob)
    if (glob ~ /\/\*\*$/) {
      sub(/\/\*\*$/, "", glob)
      print cur_name "\t" glob "\tprefix"
    } else {
      print cur_name "\t" glob "\tglob"
    }
    next
  }

  # Non-list nested key resets in_paths
  in_stacks && in_paths && /^[[:space:]]+[a-zA-Z_]+:[[:space:]]/ && !/^[[:space:]]*-/ {
    in_paths = 0; next
  }
  ' "$config"
}

# ---------------------------------------------------------------------------
# normalize_glob — strip leading "gaia-public/" and classify the pattern.
#
# This is a utility used by callers that hold raw glob strings from YAML;
# parse_stacks() already does this normalization internally, but normalize_glob
# remains a public function for NFR-052 coverage and external callers.
#
# Input:  "gaia-public/plugins/gaia/scripts/**"
# Output: "plugins/gaia/scripts"  (/** stripped)
#
# For non-/** globs:
# Input:  "gaia-public/config/*.yaml"
# Output: "config/*.yaml"         (prefix only stripped, pattern kept)
# ---------------------------------------------------------------------------
normalize_glob() {
  local glob="$1"
  # Strip leading gaia-public/
  glob="${glob#gaia-public/}"
  # Strip trailing /** only (not /*)
  if [[ "$glob" == *"/**" ]]; then
    glob="${glob%/**}"
  fi
  printf '%s' "$glob"
}

# ---------------------------------------------------------------------------
# find_best_prefix_match — longest-prefix match across all prefix-type rows
#
# Args:
#   $1 — changed file path (no gaia-public/ prefix)
#   $2 — path to stacks table file (TSV: name<TAB>candidate<TAB>match_type)
#
# Output: the stack name with the longest matching prefix, or empty string.
# Ties break by declaration order (first declared wins among equal-length).
# ---------------------------------------------------------------------------
find_best_prefix_match() {
  local path="$1"
  local stacks_table="$2"
  local best_name=""
  local best_len=0
  local name candidate match_type clen

  while IFS=$'\t' read -r name candidate match_type; do
    [[ "$match_type" == "prefix" ]] || continue
    # Require a path-segment boundary: path must be candidate/... or == candidate
    if [[ "$path" == "${candidate}/"* ]] || [[ "$path" == "$candidate" ]]; then
      clen="${#candidate}"
      if (( clen > best_len )); then
        best_len=$clen
        best_name=$name
      fi
    fi
  done < "$stacks_table"

  printf '%s' "$best_name"
}

# ---------------------------------------------------------------------------
# find_glob_match — bash glob match across all glob-type rows
#
# Args:
#   $1 — changed file path (no gaia-public/ prefix)
#   $2 — path to stacks table file (TSV: name<TAB>candidate<TAB>match_type)
#
# Output: the first stack name whose glob pattern covers the path, or empty.
# Declaration order is the tiebreaker (first match wins).
# ---------------------------------------------------------------------------
find_glob_match() {
  local path="$1"
  local stacks_table="$2"
  local name candidate match_type

  while IFS=$'\t' read -r name candidate match_type; do
    [[ "$match_type" == "glob" ]] || continue
    # bash [[ == ]] glob: * matches / so we must guard against single-level globs
    # matching deep paths (e.g. config/*.yaml must NOT match config/sub/deep.yaml).
    # Strategy: when the glob does NOT contain **, strip the literal prefix up to
    # the first wildcard; if the remaining path segment contains a /, the path is
    # deeper than the glob allows.
    if [[ "$candidate" != *"**"* ]]; then
      local glob_prefix="${candidate%%\**}"
      local glob_remainder="${path#$glob_prefix}"
      # If the remainder (after the literal prefix) contains a slash, the path
      # goes deeper than a single * can legitimately reach.
      if [[ "$glob_remainder" == */* ]]; then
        continue
      fi
    fi
    if [[ "$path" == $candidate ]]; then
      printf '%s' "$name"
      return 0
    fi
  done < "$stacks_table"

  printf ''
}

# ---------------------------------------------------------------------------
# match_path — resolve a single path to its owning stack name (or empty)
#
# Strategy (AC1/AC2/AC3):
#   1. find_best_prefix_match — longest-prefix wins
#   2. find_glob_match — fallback for non-/** patterns
#
# Outputs the matched stack name to stdout, or nothing on no match.
# Verbose decisions go to stderr.
# ---------------------------------------------------------------------------
match_path() {
  local path="$1"
  local stacks_table="$2"
  local matched=""

  matched="$(find_best_prefix_match "$path" "$stacks_table")"

  if [[ -n "$matched" ]]; then
    [[ "$VERBOSE" -eq 1 ]] && printf '[PREFIX-MATCH] path=%s stack=%s\n' "$path" "$matched" >&2
    printf '%s\n' "$matched"
    return 0
  fi

  matched="$(find_glob_match "$path" "$stacks_table")"

  if [[ -n "$matched" ]]; then
    [[ "$VERBOSE" -eq 1 ]] && printf '[GLOB-MATCH] path=%s stack=%s\n' "$path" "$matched" >&2
    printf '%s\n' "$matched"
    return 0
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '[NO-MATCH] path=%s\n' "$path" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# build_json_array — read stack names one-per-line from stdin, dedup, emit JSON
# ---------------------------------------------------------------------------
build_json_array() {
  local -a seen=()
  local line already s

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    already=0
    for s in "${seen[@]+"${seen[@]}"}"; do
      if [[ "$s" == "$line" ]]; then already=1; break; fi
    done
    if [[ "$already" -eq 0 ]]; then seen+=("$line"); fi
  done

  if [[ ${#seen[@]} -eq 0 ]]; then
    printf '[]'
    return
  fi

  local i
  printf '['
  for i in "${!seen[@]}"; do
    if [[ $i -gt 0 ]]; then printf ','; fi
    printf '"%s"' "${seen[$i]}"
  done
  printf ']'
}

# Global temp file for stacks table — must be global so the EXIT trap can
# reference it after main() returns (local vars are out of scope at trap time).
_STACKS_TABLE=""

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  # Note: promotion-push early-return is inside parse_args (AC4)

  _STACKS_TABLE="$(mktemp)"
  # shellcheck disable=SC2064
  trap 'rm -f "$_STACKS_TABLE"' EXIT
  local stacks_table="$_STACKS_TABLE"

  parse_stacks "$CONFIG" > "$stacks_table"

  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '[DEBUG] Parsed stacks table:\n' >&2
    cat "$stacks_table" >&2
  fi

  local -a paths=()

  if [[ -n "$FILES_FROM" ]]; then
    if [[ ! -f "$FILES_FROM" ]]; then
      printf 'detect-affected.sh: --files-from file not found: %s\n' "$FILES_FROM" >&2
      exit 1
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] && paths+=("$line")
    done < "$FILES_FROM"
  fi

  if [[ ${#INLINE_FILES[@]} -gt 0 ]]; then
    paths+=("${INLINE_FILES[@]}")
  fi

  if [[ ${#paths[@]} -eq 0 ]]; then
    printf '[]\n'
    return
  fi

  {
    local p
    for p in "${paths[@]}"; do
      match_path "$p" "$stacks_table"
    done
  } | build_json_array

  printf '\n'
}

# Main-guard: only invoke main when executed directly (not when sourced).
# Required for NFR-052 — sourcing must expose public functions without side-effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
