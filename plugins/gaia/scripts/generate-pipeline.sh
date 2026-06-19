#!/usr/bin/env bash
# generate-pipeline.sh — per-stack CI matrix jobs from affected-set JSON
#
# Purpose:
#   Consumes an affected-set JSON array produced by detect-affected.sh and
#   emits a GitHub Actions matrix strategy JSON object so that only the test
#   suites for affected stacks are scheduled in CI.
#
#   This script explicitly does NOT use GitHub native paths: triggers, which
#   cannot express transitive cross_refs dependencies. The GAIA pipeline
#   generator owns scope selection.
#
# Usage:
#   generate-pipeline.sh --affected-set <json-array>
#   generate-pipeline.sh --from <file>
#   generate-pipeline.sh [--config <project-config.yaml>] < affected-set.json
#
#   Flags:
#     --affected-set <json>  Inline JSON array of affected stack names.
#     --from <file>          Read the JSON array from a file.
#     --config <yaml>        Path to project-config.yaml (required for ["*"]).
#     --help                 Print usage and exit 0.
#
# Output format (GitHub Actions matrix strategy JSON):
#   {"include":[{"stack":"stack-a"},{"stack":"stack-b"}]}
#   Empty set emits: {"include":[]}
#
# Exit codes:
#   0 — success
#   1 — caller error (missing arg, file not found, ["*"] without --config)
#
# Design notes:
#   - Input priority: --affected-set > --from > stdin.
#   - Stdin is consumed only when neither --affected-set nor --from is given
#     and stdin is not a terminal ([ -t 0 ] guard).
#   - parse_stacks_names is intentionally named differently from detect-affected.sh's
#     parse_stacks so there is no symbol collision when both scripts are sourced
#     in the same bats test file.
#   - parse_affected_array uses POSIX awk only (no gensub, no 3-arg match).
#   - build_matrix_json uses pure bash; no jq dependency.
#
# POSIX awk compatibility: parse_affected_array and parse_stacks_names use
# sub/gsub only (no gensub, no 3-arg match) to work with both macOS awk
# (BSD) and GNU awk.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# usage — print help to stdout and exit 0
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  generate-pipeline.sh --affected-set <json-array>
  generate-pipeline.sh --from <file>
  generate-pipeline.sh [--config <project-config.yaml>] < affected-set.json

Options:
  --affected-set JSON   Inline JSON array of affected stack names.
  --from FILE           Read the JSON array from a file.
  --config FILE         Path to project-config.yaml (required for ["*"]).
  --help                Print this message and exit 0.

Output:
  {"include":[{"stack":"name"},...]}} on stdout.
  Empty input emits {"include":[]}.

Exit codes:
  0  Success.
  1  Caller error (missing arg, file not found, ["*"] without --config).
USAGE
}

# ---------------------------------------------------------------------------
# parse_args — populate _AFFECTED_SET_INLINE, _FROM_FILE, _CONFIG
# No I/O side effects.
# ---------------------------------------------------------------------------
parse_args() {
  _AFFECTED_SET_INLINE=""
  _FROM_FILE=""
  _CONFIG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --affected-set)
        _AFFECTED_SET_INLINE="$2"; shift 2 ;;
      --from)
        _FROM_FILE="$2"; shift 2 ;;
      --config)
        _CONFIG="$2"; shift 2 ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        printf 'generate-pipeline.sh: unknown option: %s\n' "$1" >&2
        exit 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# read_affected_json — resolve the raw JSON string from the configured source.
#
# Priority: --affected-set > --from > stdin.
# Errors if --from file is missing or if no source is available and stdin
# is a terminal ([ -t 0 ]).
# Prints the raw JSON to stdout.
# ---------------------------------------------------------------------------
read_affected_json() {
  if [[ -n "$_AFFECTED_SET_INLINE" ]]; then
    printf '%s' "$_AFFECTED_SET_INLINE"
    return 0
  fi

  if [[ -n "$_FROM_FILE" ]]; then
    if [[ ! -f "$_FROM_FILE" ]]; then
      printf 'generate-pipeline.sh: --from file not found: %s\n' "$_FROM_FILE" >&2
      exit 1
    fi
    cat "$_FROM_FILE"
    return 0
  fi

  # stdin fallback: refuse if stdin is a terminal (no piped input) or empty
  if [ -t 0 ]; then
    printf 'generate-pipeline.sh: no input source — pass --affected-set, --from, or pipe JSON via stdin\n' >&2
    usage >&2
    exit 1
  fi

  local stdin_content
  stdin_content="$(cat)"
  if [[ -z "$stdin_content" ]]; then
    printf 'generate-pipeline.sh: stdin was empty — pass --affected-set, --from, or pipe a JSON array\n' >&2
    exit 1
  fi
  printf '%s' "$stdin_content"
}

# ---------------------------------------------------------------------------
# parse_affected_array — extract stack names from a JSON array string.
#
# Args: $1 — raw JSON array string (e.g. '["stack-alpha","stack-beta"]')
# Output: one stack name per line on stdout.
# [] → zero lines; ["*"] → one line containing "*".
#
# POSIX awk only (sub/gsub, no gensub, no 3-arg match).
# ---------------------------------------------------------------------------
parse_affected_array() {
  local json="$1"
  printf '%s' "$json" | awk '
  {
    line = $0
    # Strip outer [ and ]
    sub(/^[[:space:]]*\[/, "", line)
    sub(/\][[:space:]]*$/, "", line)
    gsub(/[[:space:]]/, "", line)
    if (line == "") next
    # Split on comma
    n = split(line, tokens, ",")
    for (i = 1; i <= n; i++) {
      tok = tokens[i]
      # Strip surrounding double quotes
      gsub(/^"/, "", tok)
      gsub(/"$/, "", tok)
      # Strip surrounding single quotes (defensive)
      gsub(/^'"'"'/, "", tok)
      gsub(/'"'"'$/, "", tok)
      if (tok != "") print tok
    }
  }
  '
}

# ---------------------------------------------------------------------------
# parse_stacks_names — read stacks[].name from a project-config.yaml.
#
# Emits stack names one per line in declaration order.
# Intentionally named differently from detect-affected.sh's parse_stacks
# to avoid symbol collision when both scripts are sourced in the same session.
#
# POSIX awk only (sub/gsub, no gensub, no 3-arg match).
# ---------------------------------------------------------------------------
parse_stacks_names() {
  local config="$1"
  awk '
  BEGIN { in_stacks = 0 }

  /^stacks:/ { in_stacks = 1; next }

  # Any top-level key (no leading whitespace) exits the stacks block
  in_stacks && /^[a-zA-Z_]/ { in_stacks = 0; next }

  # New stack entry: "  - name: <value>"
  in_stacks && /^[[:space:]]+-[[:space:]]+name:/ {
    val = $0
    sub(/.*name:[[:space:]]*/, "", val)
    gsub(/^[[:space:]]+/, "", val)
    gsub(/[[:space:]]+$/, "", val)
    gsub(/^"/, "", val); gsub(/"$/, "", val)
    gsub(/^'"'"'/, "", val); gsub(/'"'"'$/, "", val)
    if (val != "") print val
  }
  ' "$config"
}

# ---------------------------------------------------------------------------
# build_matrix_json — read stack names one-per-line from stdin, emit matrix.
#
# Output format: {"include":[{"stack":"a"},{"stack":"b"}]}
# Empty input   → {"include":[]}
# Pure bash; no jq.
# ---------------------------------------------------------------------------
build_matrix_json() {
  local -a names=()
  local line

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    names+=("$line")
  done

  printf '{"include":['
  local i
  for i in "${!names[@]}"; do
    if [[ $i -gt 0 ]]; then printf ','; fi
    printf '{"stack":"%s"}' "${names[$i]}"
  done
  printf ']}'
  printf '\n'
}

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  local raw
  raw="$(read_affected_json)"

  local names
  names="$(parse_affected_array "$raw")"

  # Check for wildcard token
  if [[ "$names" == "*" ]]; then
    if [[ -z "$_CONFIG" ]]; then
      printf 'generate-pipeline.sh: --config is required when affected-set is ["*"]\n' >&2
      exit 1
    fi
    if [[ ! -f "$_CONFIG" ]]; then
      printf 'generate-pipeline.sh: config file not found: %s\n' "$_CONFIG" >&2
      exit 1
    fi
    parse_stacks_names "$_CONFIG" | build_matrix_json
    return 0
  fi

  if [[ -z "$names" ]]; then
    printf '{"include":[]}\n'
    return 0
  fi

  printf '%s\n' "$names" | build_matrix_json
}

# Main-guard: only invoke main when executed directly (not when sourced).
# Required for NFR-052 — sourcing must expose public functions without side-effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
