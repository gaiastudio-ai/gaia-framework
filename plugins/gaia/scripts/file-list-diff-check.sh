#!/usr/bin/env bash
# file-list-diff-check.sh — GAIA shared review-skill script
#
# Compares the story `## File List` section against `git diff --name-only`
# (against the configured base branch) and emits a divergence Warning in
# machine-parseable form when files differ. The check is non-blocking: if
# the workspace is not a git repository, or if HEAD is detached, the script
# emits a stderr warning and exits 0.
#
# Output (stdout) — single-line JSON when divergence is observed, empty
# otherwise:
#
#   {"warning":"file-list-divergence","reason":"<reason>",
#    "missing_from_file_list":[...],"extra_in_file_list":[...]}
#
# Reasons:
#   no-file-list       — story has no `## File List` section
#   empty-file-list    — section exists but contains zero file entries
#   divergence         — entries differ between story and git diff
#
# Invocation:
#   file-list-diff-check.sh --story-file <path> [--base <branch>] [--repo <dir>]
#   file-list-diff-check.sh --help
#
# Exit codes:
#   0  — success (warning may have been emitted to stdout)
#   1  — caller error (missing/unknown flag, missing required arg)
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="file-list-diff-check.sh"

die() {
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<EOF
$SCRIPT_NAME — File List vs git-diff divergence check

Usage:
  $SCRIPT_NAME --story-file <path> [--base <branch>] [--repo <dir>]
  $SCRIPT_NAME --help

Options:
  --story-file <path>  Path to story markdown (must contain '## File List') (required)
  --base <branch>      Git ref to diff against (default: main)
  --repo <dir>         Repository root (default: current directory)
  --help               Show this help and exit 0
EOF
}

STORY=""
BASE="main"
REPO=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --story-file)  [ "$#" -ge 2 ] || die 1 "--story-file requires a path"; STORY="$2"; shift 2 ;;
    --base)        [ "$#" -ge 2 ] || die 1 "--base requires a branch";     BASE="$2";  shift 2 ;;
    --repo)        [ "$#" -ge 2 ] || die 1 "--repo requires a directory";  REPO="$2";  shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$STORY" ] || die 1 "missing required --story-file <path>"
[ -r "$STORY" ] || die 1 "story file not readable: $STORY"

# --- 1. Extract File List section from story markdown ---
# Section runs from `## File List` (or `## File list`) until the next H2
# heading (`^## `) or EOF. File entries are markdown list items beginning
# with `-` or `*`. Backtick-quoted code spans are stripped.

extract_file_list() {
  awk '
    BEGIN { in_section = 0 }
    /^##[[:space:]]+[Ff]ile [Ll]ist[[:space:]]*$/ { in_section = 1; next }
    in_section && /^##[[:space:]]/                { in_section = 0 }
    in_section { print }
  ' "$STORY"
}

# Lines like "- `path/to/file.ts` — comment" or "* path".
# Strip leading dash/star + spaces, strip backticks, strip everything
# after the first whitespace (file paths must not contain spaces in the
# canonical File List; spaces are tolerated only when wrapped in backticks).
parse_file_entries() {
  extract_file_list \
    | grep -E '^[[:space:]]*[-*][[:space:]]+' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+//; s/`//g' \
    | awk '{
        # If the line starts with a quoted path with spaces, take the entire
        # remainder up to the first em-dash separator (—, --, or end-of-line);
        # otherwise take the first whitespace-delimited token.
        line = $0
        # Strip trailing comment after em-dash or " -- ".
        sub(/[[:space:]]+(—|--|—).*$/, "", line)
        # Trim leading/trailing whitespace.
        sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
        if (length(line) > 0) print line
      }'
}

FILE_LIST_SECTION="$(extract_file_list || true)"

# --- 2. Detect missing or empty File List ---
if [ -z "$(printf '%s' "$FILE_LIST_SECTION" | tr -d '[:space:]')" ]; then
  if ! grep -Eq '^##[[:space:]]+[Ff]ile [Ll]ist[[:space:]]*$' "$STORY"; then
    printf '{"warning":"file-list-divergence","reason":"no-file-list","missing_from_file_list":[],"extra_in_file_list":[]}\n'
  else
    printf '{"warning":"file-list-divergence","reason":"empty-file-list","missing_from_file_list":[],"extra_in_file_list":[]}\n'
  fi
  exit 0
fi

FILE_LIST_ENTRIES="$(parse_file_entries || true)"
if [ -z "$(printf '%s' "$FILE_LIST_ENTRIES" | tr -d '[:space:]')" ]; then
  printf '{"warning":"file-list-divergence","reason":"empty-file-list","missing_from_file_list":[],"extra_in_file_list":[]}\n'
  exit 0
fi

# --- 3. Run git diff --name-only against base ---
if [ -n "$REPO" ]; then
  cd "$REPO"
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf '%s: git diff unavailable — divergence check skipped (not in a git repository)\n' "$SCRIPT_NAME" >&2
  exit 0
fi

# Resolve base ref. If base does not exist, try common alternatives.
BASE_REF=""
for cand in "$BASE" "origin/$BASE" "main" "master" "origin/main" "origin/master"; do
  if git rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
    BASE_REF="$cand"
    break
  fi
done

if [ -z "$BASE_REF" ]; then
  printf '%s: git diff unavailable — base ref not found (tried %s)\n' "$SCRIPT_NAME" "$BASE" >&2
  exit 0
fi

# Get the list of files changed since BASE_REF (committed + uncommitted).
GIT_FILES_RAW="$(git diff --name-only "$BASE_REF" 2>/dev/null || true)"
GIT_FILES_UNCOMMITTED="$(git diff --name-only 2>/dev/null || true)"
GIT_FILES_UNTRACKED="$(git ls-files --others --exclude-standard 2>/dev/null || true)"

GIT_FILES="$(printf '%s\n%s\n%s\n' "$GIT_FILES_RAW" "$GIT_FILES_UNCOMMITTED" "$GIT_FILES_UNTRACKED" \
  | awk 'NF' | sort -u)"

# --- 4. Compute divergence ---
# Normalize entries: trim, sort -u
FILE_LIST_NORM="$(printf '%s\n' "$FILE_LIST_ENTRIES" | awk 'NF' | sort -u)"
GIT_NORM="$(printf '%s\n' "$GIT_FILES" | awk 'NF' | sort -u)"

# missing_from_file_list = in git but not in file list
MISSING="$(comm -23 <(printf '%s\n' "$GIT_NORM") <(printf '%s\n' "$FILE_LIST_NORM") || true)"
# extra_in_file_list = in file list but not in git
EXTRA="$(comm -13 <(printf '%s\n' "$GIT_NORM") <(printf '%s\n' "$FILE_LIST_NORM") || true)"

if [ -z "$(printf '%s' "$MISSING$EXTRA" | tr -d '[:space:]')" ]; then
  # No divergence — emit nothing.
  exit 0
fi

# Build JSON arrays without external tools.
to_json_array() {
  # to_json_array <newline-separated-list>
  local first=1
  printf '['
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Escape backslashes and double quotes.
    local esc
    esc="$(printf '%s' "$line" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    if [ "$first" = 1 ]; then
      printf '"%s"' "$esc"
      first=0
    else
      printf ',"%s"' "$esc"
    fi
  done <<< "$1"
  printf ']'
}

MISSING_JSON="$(to_json_array "$MISSING")"
EXTRA_JSON="$(to_json_array "$EXTRA")"

printf '{"warning":"file-list-divergence","reason":"divergence","missing_from_file_list":%s,"extra_in_file_list":%s}\n' \
  "$MISSING_JSON" "$EXTRA_JSON"
exit 0
