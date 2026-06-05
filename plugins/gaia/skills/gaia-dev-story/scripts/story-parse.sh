#!/usr/bin/env bash
# story-parse.sh — gaia-dev-story Step 1 frontmatter parser
#
# Parses a story file's YAML frontmatter and Tasks/AC sections, then emits the
# canonical 10-variable env-var dump on stdout. Designed for `eval "$(...)"`
# consumption — every value is single-quoted and shell-metachar safe.
#
# Usage:
#   story-parse.sh <story_path>
#
# Canonical env-vars (stable contract — renaming any is a breaking change):
#   STORY_KEY        — story key from frontmatter `key`
#   STATUS           — story status from frontmatter `status`
#   RISK             — risk level from frontmatter `risk` (may be empty)
#   EPIC_KEY         — epic key from frontmatter `epic`
#   TYPE             — template type from frontmatter `template` (e.g. "story")
#   DEPENDS_ON       — comma-joined depends_on list (empty if none)
#   SUBTASK_COUNT    — total `- [ ]` + `- [x]` items under "## Tasks / Subtasks"
#   SUBTASK_CHECKED  — count of `- [x]` items under "## Tasks / Subtasks"
#   AC_COUNT         — count of `- [ ]`/`- [x]` items under "## Acceptance Criteria"
#   STORY_PATH       — absolute path passed in (validated)
#
# Exit codes:
#   0 — success; 10 KEY='value' lines on stdout
#   1 — usage error / missing file (stderr names path)
#   2 — malformed frontmatter / missing required field (stderr names problem)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/story-parse.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; exit 1; }
die_parse() { log "$*"; exit 2; }

# --- Arg validation -------------------------------------------------------

if [ $# -lt 1 ]; then
  die_usage "usage: story-parse.sh <story_path>"
fi

STORY_PATH_INPUT="$1"

# Path traversal rejection — defense in depth. Reject ANY '..' in the
# path before any filesystem access.
case "$STORY_PATH_INPUT" in
  *..*)
    die_usage "path traversal rejected: $STORY_PATH_INPUT"
    ;;
esac

# --- File existence -------------------------------------------------------

if [ ! -f "$STORY_PATH_INPUT" ]; then
  die_usage "story file not found: $STORY_PATH_INPUT"
fi

# --- Frontmatter extraction -----------------------------------------------
#
# Frontmatter lives between the first two `---` lines. If the second `---` is
# absent we exit 2 (malformed). The shared frontmatter-lib.sh provides the
# slicing and field-reading primitives.

# shellcheck source=./frontmatter-lib.sh
SCRIPT_DIR_FOR_LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR_FOR_LIB/frontmatter-lib.sh"

FRONTMATTER="$(fm_slice "$STORY_PATH_INPUT")" || die_parse "malformed frontmatter (unbalanced '---' markers): $STORY_PATH_INPUT"

# --- Field extraction -----------------------------------------------------
get_field() {
  local key="$1"
  printf '%s\n' "$FRONTMATTER" | fm_get_field "$key"
}

# get_field_aliased CANONICAL ALIAS — return the canonical frontmatter field
# if present, otherwise fall back to the alias. Tolerates the `story_key:` /
# `epic_key:` convention every other story-consuming skill already accepts.
# Backward- and forward-compatible: canonical `key:` / `epic:` continue to
# take precedence.
get_field_aliased() {
  local canonical="$1" alias="$2" val
  val="$(get_field "$canonical")"
  if [ -z "$val" ]; then
    val="$(get_field "$alias")"
  fi
  printf '%s' "$val"
}

# Special handling for depends_on: emit comma-joined list. Supports the
# common YAML inline form `depends_on: ["E1-S1", "E1-S2"]` and the empty
# form `depends_on: []`.
get_depends_on() {
  local raw
  raw="$(get_field depends_on)"
  if [ -z "$raw" ]; then
    printf ''
    return
  fi
  # Strip surrounding [] if present
  raw="${raw#[}"
  raw="${raw%]}"
  # Empty list after stripping
  if [ -z "$raw" ] || [ "$raw" = " " ]; then
    printf ''
    return
  fi
  # Strip quotes and whitespace from each comma-separated item
  printf '%s' "$raw" | awk -F',' '
    {
      out = ""
      for (i = 1; i <= NF; i++) {
        x = $i
        gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", x)
        if (x == "") continue
        if (out == "") out = x
        else out = out "," x
      }
      printf "%s", out
    }
  '
}

STORY_KEY_VAL="$(get_field_aliased key story_key)"
STATUS_VAL="$(get_field status)"
RISK_VAL="$(get_field risk)"
EPIC_KEY_VAL="$(get_field_aliased epic epic_key)"
TYPE_VAL="$(get_field template)"
DEPENDS_ON_VAL="$(get_depends_on)"
STORY_PATH_VAL="$STORY_PATH_INPUT"

# Validate required fields
if [ -z "$STORY_KEY_VAL" ]; then
  die_parse "missing required frontmatter field: key (or alias story_key)"
fi
if [ -z "$STATUS_VAL" ]; then
  die_parse "missing required frontmatter field: status"
fi

# --- Subtask + AC counts --------------------------------------------------
#
# Count `- [ ]` / `- [x]` lines under each section heading. A section ends at
# the next `## ` heading. We accept "## Tasks / Subtasks" and
# "## Acceptance Criteria" as the canonical headings.

count_section() {
  local heading="$1" pattern="$2"
  awk -v heading="$heading" -v pattern="$pattern" '
    BEGIN { in_section = 0; count = 0 }
    {
      # Detect section start
      if ($0 == heading) { in_section = 1; next }
      # Detect next section start (any "## " heading)
      if (in_section && $0 ~ /^## /) { in_section = 0 }
      if (in_section && $0 ~ pattern) count++
    }
    END { print count }
  ' "$STORY_PATH_INPUT"
}

SUBTASK_COUNT_VAL="$(count_section "## Tasks / Subtasks" '^[[:space:]]*-[[:space:]]+\\[[ x]\\]')"
SUBTASK_CHECKED_VAL="$(count_section "## Tasks / Subtasks" '^[[:space:]]*-[[:space:]]+\\[x\\]')"
AC_COUNT_VAL="$(count_section "## Acceptance Criteria" '^[[:space:]]*-[[:space:]]+\\[[ x]\\]')"

# --- Single-quote escape + emit ------------------------------------------
#
# Standard shell idiom: wrap value in single quotes, replacing each interior
# single quote with the sequence '\''  (close, escaped quote, reopen).
shell_quote() {
  local s="$1"
  # Replace ' with '\''
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# Emit on stdout (only after all parsing succeeded — never partial output)
printf "STORY_KEY=%s\n" "$(shell_quote "$STORY_KEY_VAL")"
printf "STATUS=%s\n" "$(shell_quote "$STATUS_VAL")"
printf "RISK=%s\n" "$(shell_quote "$RISK_VAL")"
printf "EPIC_KEY=%s\n" "$(shell_quote "$EPIC_KEY_VAL")"
printf "TYPE=%s\n" "$(shell_quote "$TYPE_VAL")"
printf "DEPENDS_ON=%s\n" "$(shell_quote "$DEPENDS_ON_VAL")"
printf "SUBTASK_COUNT=%s\n" "$(shell_quote "$SUBTASK_COUNT_VAL")"
printf "SUBTASK_CHECKED=%s\n" "$(shell_quote "$SUBTASK_CHECKED_VAL")"
printf "AC_COUNT=%s\n" "$(shell_quote "$AC_COUNT_VAL")"
printf "STORY_PATH=%s\n" "$(shell_quote "$STORY_PATH_VAL")"

exit 0
