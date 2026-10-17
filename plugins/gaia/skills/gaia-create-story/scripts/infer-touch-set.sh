#!/usr/bin/env bash
# infer-touch-set.sh — deterministic touch-set inference helper
#
# Extracts candidate file paths from:
#   1. Quoted or backtick-delimited paths in AC text
#   2. Prior same-epic stories' existing predicted_touch_set union
#
# Output: one PROJECT_ROOT-relative candidate path per line.
# Empty output means nothing was inferred.
# No mode flags — output is identical regardless of caller context.
#
# Usage:
#   infer-touch-set.sh --ac-file <path> --epic-dir <path> [--story-files <file>...]
#
# Exit codes:
#   0 — success (output may be empty)
#   2 — usage error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="infer-touch-set.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: infer-touch-set.sh --ac-file <path> --epic-dir <path> [--story-files <file>...]

  --ac-file <path>       File containing acceptance criteria text. Required.
  --epic-dir <path>      Epic directory containing prior story files. Required.
  --story-files <file>   Additional prior story files (repeatable). Optional.

Output (stdout): one PROJECT_ROOT-relative candidate path per line.
Empty output means nothing was inferred.

Exit codes: 0 success | 2 usage error.
USAGE
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; usage; exit 2; }

# --- CLI parsing ---

ac_file=""
epic_dir=""
story_files=()

while [ $# -gt 0 ]; do
  case "$1" in
    --ac-file)
      [ $# -ge 2 ] || die_usage "--ac-file requires a value"
      ac_file="$2"; shift 2 ;;
    --epic-dir)
      [ $# -ge 2 ] || die_usage "--epic-dir requires a value"
      epic_dir="$2"; shift 2 ;;
    --story-files)
      [ $# -ge 2 ] || die_usage "--story-files requires a value"
      story_files+=("$2"); shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$ac_file" ]  || die_usage "--ac-file is required"
[ -n "$epic_dir" ] || die_usage "--epic-dir is required"

# --- AC-text path extraction ---
# Extract paths from backtick-delimited or quoted strings in the AC text.
# Deterministic subset: only paths that look like file paths (contain / or
# end with a common extension).

_ts_field="predicted_touch_set"

candidates=""

if [ -r "$ac_file" ]; then
  # Extract backtick-delimited paths: `some/path/file.sh`
  # and double-quoted paths: "some/path/file.sh"
  # Filter to those containing a / or ending with a file extension.
  # shellcheck disable=SC2016
  ac_paths="$(grep -oE '`[^`]+`|"[^"]+"' "$ac_file" 2>/dev/null | \
    sed 's/^`//; s/`$//; s/^"//; s/"$//' | \
    grep -E '(/|(\.(sh|md|yaml|yml|json|ts|js|py|bats|css|html|toml|txt|cfg))$)' | \
    sort -u || true)"
  if [ -n "$ac_paths" ]; then
    candidates="${candidates}${ac_paths}"$'\n'
  fi
fi

# --- Epic scope inference ---
# Union of prior same-epic stories' existing predicted_touch_set values.

_read_touch_set_from_file() {
  local f="$1"
  [ -r "$f" ] || return 0
  # Use yq to read the field; fallback to empty on error.
  TS_FIELD="$_ts_field" yq --front-matter=extract -r \
    '.[strenv(TS_FIELD)] // [] | .[]' "$f" 2>/dev/null || true
}

# Find story files in the epic directory.
if [ -d "$epic_dir" ]; then
  while IFS= read -r -d '' sf; do
    epic_vals="$(_read_touch_set_from_file "$sf")"
    if [ -n "$epic_vals" ]; then
      candidates="${candidates}${epic_vals}"$'\n'
    fi
  done < <(find "$epic_dir" -name 'story.md' -print0 2>/dev/null || true)
fi

# Additional story files passed via --story-files.
for sf in "${story_files[@]+"${story_files[@]}"}"; do
  epic_vals="$(_read_touch_set_from_file "$sf")"
  if [ -n "$epic_vals" ]; then
    candidates="${candidates}${epic_vals}"$'\n'
  fi
done

# --- Deduplicate and emit ---

if [ -n "$candidates" ]; then
  printf '%s' "$candidates" | grep -v '^[[:space:]]*$' | sort -u
fi

exit 0
