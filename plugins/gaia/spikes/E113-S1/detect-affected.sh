#!/usr/bin/env bash
# detect-affected.sh — E113-S1 SPIKE: selective-test-execution feasibility
#
# Maps a list of changed-file paths to the stack names declared in a
# project-config.yaml, using the same glob logic that a CI runner would apply.
#
# Usage:
#   detect-affected.sh --config <project-config.yaml> --files-from <file-list.txt>
#   detect-affected.sh --config <project-config.yaml> --files f1.sh f2.sh ...
#
# Flags:
#   --config      Path to project-config.yaml
#   --files-from  Text file of newline-separated changed paths (from git diff --name-only)
#   --files       Inline list of changed paths (alternative to --files-from)
#   --verbose     Write per-path match decisions to stderr (never stdout)
#
# Output: a JSON array of matched stack names, deduplicated, on stdout.
#         Always exits 0, even when no stacks match (emits []).
#
# Design notes (Val-confirmed):
#   - project-config.yaml globs carry a "gaia-public/" prefix
#   - git diff --name-only returns paths WITHOUT that prefix
#   - This script strips "gaia-public/" from each config glob before matching
#   - bash ** is not recursive; script strips trailing /** and does prefix match
#   - config/ subdir is intentionally NOT in the glob list — real false-negative
#     documented, tracked for S2
#
# POSIX awk compatibility: uses sub/gsub only (no 3-arg match, no gensub)
# so it works with both macOS awk (BSD/one true awk) and GNU awk.

set -euo pipefail

# ---------------------------------------------------------------------------
# parse_args — populate CONFIG, FILES_FROM, INLINE_FILES, VERBOSE
# ---------------------------------------------------------------------------
parse_args() {
  CONFIG=""
  FILES_FROM=""
  INLINE_FILES=()
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
      --verbose)
        VERBOSE=1; shift ;;
      *)
        printf 'detect-affected.sh: unknown option: %s\n' "$1" >&2
        exit 1 ;;
    esac
  done

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
# parse_stacks — read stacks[].name and stacks[].paths from YAML using awk.
#
# The YAML shape we handle (from project-config.yaml):
#
#   stacks:
#     - name: gaia-plugin
#       language: bash
#       paths:
#         - "gaia-public/plugins/gaia/scripts/**"
#         - "gaia-public/plugins/gaia/skills/**"
#
# Output: one record per (stack_name, glob) pair, tab-separated, on stdout.
#
# Uses POSIX awk only (sub/gsub/index, no 3-arg match, no gensub) to ensure
# compatibility with BSD awk on macOS.
# ---------------------------------------------------------------------------
parse_stacks() {
  local config="$1"
  awk '
  BEGIN { in_stacks=0; in_paths=0; cur_name=""; }

  # Enter the stacks: block (top-level key with no leading whitespace)
  /^stacks:/ { in_stacks=1; next }

  # Top-level key encountered while in stacks block — exit stacks
  in_stacks && /^[a-zA-Z_]/ { in_stacks=0; in_paths=0; cur_name=""; next }

  # A new stack entry: "  - name: <value>"
  in_stacks && /^[[:space:]]+-[[:space:]]+name:/ {
    cur_name = $0
    # Remove everything up to and including "name:"
    sub(/.*name:[[:space:]]*/, "", cur_name)
    # Strip surrounding whitespace and quotes
    gsub(/^[[:space:]]+/, "", cur_name)
    gsub(/[[:space:]]+$/, "", cur_name)
    gsub(/^"/, "", cur_name)
    gsub(/"$/, "", cur_name)
    gsub(/^'"'"'/, "", cur_name)
    gsub(/'"'"'$/, "", cur_name)
    in_paths=0
    next
  }

  # The paths: key under a stack entry
  in_stacks && cur_name != "" && /^[[:space:]]+paths:[[:space:]]*$/ {
    in_paths=1
    next
  }

  # A path glob entry with double quotes: "      - \"glob/**\""
  in_stacks && in_paths && cur_name != "" && /^[[:space:]]+-[[:space:]]+"/ {
    glob = $0
    sub(/^[[:space:]]*-[[:space:]]*"/, "", glob)
    sub(/"[[:space:]]*$/, "", glob)
    if (glob != "") {
      print cur_name "\t" glob
    }
    next
  }

  # A path glob entry with single quotes
  in_stacks && in_paths && cur_name != "" && /^[[:space:]]+-[[:space:]]+'"'"'/ {
    glob = $0
    sub(/^[[:space:]]*-[[:space:]]*'"'"'/, "", glob)
    sub(/'"'"'[[:space:]]*$/, "", glob)
    if (glob != "") {
      print cur_name "\t" glob
    }
    next
  }

  # A non-list nested key while in paths resets in_paths
  in_stacks && in_paths && /^[[:space:]]+[a-zA-Z_]+:[[:space:]]/ && !/^[[:space:]]*-/ {
    in_paths=0
    next
  }
  ' "$config"
}

# ---------------------------------------------------------------------------
# normalize_glob — strip the "gaia-public/" prefix and the trailing "/**"
# so we can do a simple prefix match against git-diff paths (which lack the
# "gaia-public/" prefix).
#
# Input:  "gaia-public/plugins/gaia/scripts/**"
# Output: "plugins/gaia/scripts"
#
# Only strips "/**" (double-star) at the end, not "/*" — stripping "/*"
# would over-generalise the prefix and cause false positives (e.g. matching
# plugins/gaia/config/* against the plugins/gaia/scripts/** glob).
# ---------------------------------------------------------------------------
normalize_glob() {
  local glob="$1"
  # Strip leading gaia-public/
  glob="${glob#gaia-public/}"
  # Strip trailing /** only — do NOT strip /* (single star is more specific)
  if [[ "$glob" == *"/**" ]]; then
    glob="${glob%/**}"
  fi
  printf '%s' "$glob"
}

# ---------------------------------------------------------------------------
# match_path — for a single changed path, return all matching stack names
# (one per line) by consulting the stacks table file.
# Writes matched stack names to stdout; per-path decisions to stderr if verbose.
# ---------------------------------------------------------------------------
match_path() {
  local path="$1"
  local stacks_table="$2"

  local name glob prefix

  while IFS=$'\t' read -r name glob; do
    prefix="$(normalize_glob "$glob")"
    if [[ "$path" == "${prefix}/"* ]] || [[ "$path" == "$prefix" ]]; then
      if [[ "$VERBOSE" -eq 1 ]]; then
        printf '[MATCH] path=%s  stack=%s  prefix=%s\n' "$path" "$name" "$prefix" >&2
      fi
      printf '%s\n' "$name"
    else
      if [[ "$VERBOSE" -eq 1 ]]; then
        printf '[SKIP]  path=%s  prefix=%s\n' "$path" "$prefix" >&2
      fi
    fi
  done < "$stacks_table"
}

# ---------------------------------------------------------------------------
# build_json_array — read stack names (one per line) from stdin, deduplicate,
# and emit a JSON array to stdout.
# ---------------------------------------------------------------------------
build_json_array() {
  local -a seen=()
  local line

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local already=0
    local s
    for s in "${seen[@]+"${seen[@]}"}"; do
      if [[ "$s" == "$line" ]]; then already=1; break; fi
    done
    if [[ "$already" -eq 0 ]]; then
      seen+=("$line")
    fi
  done

  if [[ ${#seen[@]} -eq 0 ]]; then
    printf '[]'
    return
  fi

  printf '['
  local i
  for i in "${!seen[@]}"; do
    [[ $i -gt 0 ]] && printf ','
    printf '"%s"' "${seen[$i]}"
  done
  printf ']'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Parse stacks into a temp file for repeated lookup
  local stacks_table
  stacks_table="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$stacks_table'" EXIT

  parse_stacks "$CONFIG" > "$stacks_table"

  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '[DEBUG] Parsed stacks table:\n' >&2
    cat "$stacks_table" >&2
  fi

  # Collect changed paths from --files-from and/or --files
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

  # Match each path, collect matched stack names, deduplicate, emit JSON
  {
    local p
    for p in "${paths[@]}"; do
      match_path "$p" "$stacks_table"
    done
  } | build_json_array

  printf '\n'
}

main "$@"
