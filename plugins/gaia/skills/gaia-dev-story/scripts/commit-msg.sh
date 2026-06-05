#!/usr/bin/env bash
# commit-msg.sh — gaia-dev-story Step 10 commit-message helper
#
# Reads a story file's YAML frontmatter (key, title, type) and emits a
# Conventional Commit message on stdout. The output is safe to feed to
# `git commit -F -`.
#
# Usage:
#   commit-msg.sh <story_path>
#
# Output (subject line + optional body):
#   <type>(<story_key>): <story_title>
#
# Type mapping (from frontmatter `type:` field):
#   feature  -> feat
#   bug      -> fix
#   refactor -> refactor
#   chore    -> chore
#   missing or unrecognized -> feat (default)
#
# The subject line matches:
#   ^(feat|fix|refactor|chore)\([A-Z][0-9]+-S[0-9]+\): .+$
#
# Hard rules (per CLAUDE.md):
#   - The shell-builtin string-execution primitive is banned outright.
#     Frontmatter is parsed via awk; values flow through `printf '%s'` —
#     never echo, never command substitution into shell.
#   - No `Claude`, `AI`, or `Co-Authored-By` strings emitted.
#
# Exit codes:
#   0 — success; message printed on stdout.
#   1 — usage error / missing file.
#   2 — malformed frontmatter / missing required field (key or title).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/commit-msg.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; exit 1; }
die_parse() { log "$*"; exit 2; }

# --- Arg validation -------------------------------------------------------

if [ $# -lt 1 ]; then
  die_usage "usage: commit-msg.sh <story_path>"
fi

STORY_PATH_INPUT="$1"

# Path-traversal rejection (defense in depth)
case "$STORY_PATH_INPUT" in
  *..*) die_usage "path traversal rejected: $STORY_PATH_INPUT" ;;
esac

if [ ! -f "$STORY_PATH_INPUT" ]; then
  die_usage "story file not found: $STORY_PATH_INPUT"
fi

# --- Frontmatter extraction (shared via frontmatter-lib.sh) --

SCRIPT_DIR_FOR_LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./frontmatter-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR_FOR_LIB/frontmatter-lib.sh"

FRONTMATTER="$(fm_slice "$STORY_PATH_INPUT")" || die_parse "malformed frontmatter (unbalanced '---' markers): $STORY_PATH_INPUT"

get_field() {
  local key="$1"
  printf '%s\n' "$FRONTMATTER" | fm_get_field "$key"
}

# Tolerate the `story_key:` convention every other story-consuming skill
# accepts; canonical `key:` takes precedence.
get_field_aliased() {
  local canonical="$1" alias="$2" val
  val="$(get_field "$canonical")"
  if [ -z "$val" ]; then
    val="$(get_field "$alias")"
  fi
  printf '%s' "$val"
}

STORY_KEY_VAL="$(get_field_aliased key story_key)"
TITLE_VAL="$(get_field title)"
TYPE_VAL="$(get_field type)"

if [ -z "$STORY_KEY_VAL" ]; then
  die_parse "missing required frontmatter field: key (or alias story_key)"
fi
if [ -z "$TITLE_VAL" ]; then
  die_parse "missing required frontmatter field: title"
fi

# --- Type mapping ---------------------------------------------------------
#
# PREFIX is the Conventional-Commit `<type>` token; VERB is the lowercase
# leading word prepended to the subject body so commitlint's subject-case
# rule (which rejects start-case / pascal-case / upper-case) accepts ALL-CAPS
# story titles like "SKILL.md gate wiring" without manual `gh pr edit`
# intervention.

case "$TYPE_VAL" in
  feature)  PREFIX="feat";     VERB="wire" ;;
  bug)      PREFIX="fix";      VERB="fix" ;;
  refactor) PREFIX="refactor"; VERB="refactor" ;;
  chore)    PREFIX="chore";    VERB="update" ;;
  *)        PREFIX="feat";     VERB="wire" ;;  # default for unrecognized or missing
esac

# --- Title sanitization ---------------------------------------------------
#
# Newlines must not break the single-line subject contract. Carriage returns
# get the same treatment for safety against CRLF input.
TITLE_ONELINE="$(printf '%s' "$TITLE_VAL" | tr '\r\n' '  ')"

# --- Subject body: prepend lowercase verb when needed ---------------------
#
# Skip the prefix when the title already starts with a lowercase ASCII verb
# (so re-running on `wire X` does not produce `wire wire X`). Otherwise
# always prepend `<VERB> ` so the subject body's first character is
# lowercase — that is what commitlint's `subject-case` rule cares about.
#
# Detection: `[[ "$TITLE_ONELINE" =~ ^[a-z] ]]` — strict ASCII lower-case
# regex. Anything else (uppercase, digit, symbol, empty) gets the prefix.
if [[ "$TITLE_ONELINE" =~ ^[a-z] ]]; then
  SUBJECT_BODY="$TITLE_ONELINE"
else
  SUBJECT_BODY="$VERB $TITLE_ONELINE"
fi

# --- Subject construction + 72-char cap -----------------------------------
#
# Build the subject and truncate to 72 chars. bash parameter expansion is
# byte-based; LC_ALL=C is set so length math is consistent.
SUBJECT="$(printf '%s(%s): %s' "$PREFIX" "$STORY_KEY_VAL" "$SUBJECT_BODY")"
if [ "${#SUBJECT}" -gt 72 ]; then
  SUBJECT="${SUBJECT:0:72}"
fi

# --- Emit ----------------------------------------------------------------
#
# Subject line only — body lines (traces-to, validates) are out of scope for
# the AC contract. Adding them later is a non-breaking change.
printf '%s\n' "$SUBJECT"

exit 0
