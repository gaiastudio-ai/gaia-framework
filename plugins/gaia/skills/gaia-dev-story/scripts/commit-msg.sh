#!/usr/bin/env bash
# commit-msg.sh — gaia-dev-story Step 10 commit-message helper
#
# Reads a story file's YAML frontmatter (key, title, type) and emits a
# Conventional Commit message on stdout. The output is safe to feed to
# `git commit -F -`.
#
# Usage:
#   commit-msg.sh <story_path> [--scope <product_scope>]
#
# Output (subject line + blank line + Story: body line):
#   <type>[(<scope>)]: <title>
#
#   Story: <story_key>
#
# Type mapping (from frontmatter `type:` field):
#   feature  -> feat
#   bug      -> fix
#   refactor -> refactor
#   chore    -> chore
#   missing or unrecognized -> feat (default)
#
# The --scope flag adds a product scope (e.g., sprint-state, pr-create) to the
# subject. The scope must be lowercase alphanumeric + hyphens, and must not
# look like a story key. When omitted, the subject is scopeless.
#
# Hard rules (per CLAUDE.md):
#   - The shell-builtin string-execution primitive is banned outright.
#     Frontmatter is parsed via awk; values flow through `printf '%s'` —
#     never echo, never command substitution into shell.
#   - No `Claude`, `AI`, or `Co-Authored-By` strings emitted.
#
# Exit codes:
#   0 — success; message printed on stdout.
#   1 — usage error / missing file / invalid scope.
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
  die_usage "usage: commit-msg.sh <story_path> [--scope <product_scope>]"
fi

STORY_PATH_INPUT="$1"
shift

# Parse optional --scope flag
SCOPE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        die_usage "--scope requires a non-empty value"
      fi
      SCOPE="$2"
      shift 2
      ;;
    *)
      die_usage "unknown option: $1"
      ;;
  esac
done

# Validate scope when provided
if [ -n "$SCOPE" ]; then
  # Must be lowercase alphanumeric + hyphens, starting with alnum.
  scope_re='^[a-z0-9][a-z0-9-]*$'
  if ! [[ "$SCOPE" =~ $scope_re ]]; then
    die_usage "scope must be lowercase alphanumeric + hyphens (e.g., --scope design-review): $SCOPE"
  fi
  # Must not look like a story key (case-insensitive on the S separator).
  key_shape_re='^[A-Za-z]+[0-9]+-[Ss][0-9]+$'
  if [[ "$SCOPE" =~ $key_shape_re ]]; then
    die_usage "scope must not look like a story key (e.g., --scope design-review): $SCOPE"
  fi
fi

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

# --- Strip the story's own key from the title -----------------------------
#
# When the story title contains its own key (e.g., "<KEY>: fix the thing"
# or "Fix (<KEY>) thing" or "Fix [<KEY>] regression" or "Fix <KEY>, thing"),
# strip it so the subject is clean. Any non-alphanumeric character acts as a
# word boundary — the key is removed only when both left and right neighbours
# are non-alnum (or string edges). Surrounding brackets/parens and trailing
# colon/comma/dot are consumed with the key; doubled spaces are collapsed.
#
# Over-strip guard: a longer key (e.g., K1-S10) must survive when stripping
# K1-S1. The function checks the character immediately after the key — if it
# is alphanumeric, the match is part of a longer token and is left alone.
_strip_key_from_title() {
  local s="$1" key="$2"
  local klen=${#key}
  local changed=1

  while [ "$changed" -eq 1 ]; do
    changed=0
    local i=0 slen=${#s}

    while [ "$i" -lt "$slen" ]; do
      # Quick mismatch — advance one char.
      if [ "${s:$i:$klen}" != "$key" ]; then
        i=$((i + 1)); continue
      fi

      # Candidate match at position $i. Check boundaries.
      # Left boundary: start of string, or non-alnum char before.
      if [ "$i" -gt 0 ]; then
        local lc="${s:$((i - 1)):1}"
        case "$lc" in
          [A-Za-z0-9]) i=$((i + 1)); continue ;;
        esac
      fi
      # Right boundary: end of string, or non-alnum char after.
      local after_pos=$((i + klen))
      if [ "$after_pos" -lt "$slen" ]; then
        local rc="${s:$after_pos:1}"
        case "$rc" in
          [A-Za-z0-9]) i=$((i + 1)); continue ;;
        esac
      fi

      # Valid boundary match. Compute the strip range: expand left to consume
      # a leading bracket/paren, expand right to consume trailing bracket/paren,
      # colon, comma, dot, and surrounding whitespace.
      local left="$i" right="$after_pos"

      # Consume leading bracket, paren, or colon if present.
      if [ "$left" -gt 0 ]; then
        local lp="${s:$((left - 1)):1}"
        case "$lp" in
          "["|"("|":") left=$((left - 1)) ;;
        esac
      fi

      # Consume trailing ] or ) if present.
      if [ "$right" -lt "$slen" ]; then
        local rp="${s:$right:1}"
        case "$rp" in
          "]"|")") right=$((right + 1)) ;;
        esac
      fi

      # Consume trailing colon, comma, or dot.
      if [ "$right" -lt "$slen" ]; then
        local tc="${s:$right:1}"
        case "$tc" in
          ":"|","|".") right=$((right + 1)) ;;
        esac
      fi

      # Consume whitespace on both sides of the gap.
      while [ "$right" -lt "$slen" ] && [ "${s:$right:1}" = " " ]; do
        right=$((right + 1))
      done
      while [ "$left" -gt 0 ] && [ "${s:$((left - 1)):1}" = " " ]; do
        left=$((left - 1))
      done

      # Splice: keep a single space between before and after when both exist.
      local before="${s:0:$left}" after="${s:$right}"
      if [ -n "$before" ] && [ -n "$after" ]; then
        s="${before} ${after}"
      else
        s="${before}${after}"
      fi
      changed=1; break
    done
  done

  # Collapse any doubled spaces left by stripping.
  while true; do
    case "$s" in
      *"  "*) s="${s%%  *} ${s#*  }" ;;
      *) break ;;
    esac
  done

  printf '%s' "$s"
}

TITLE_ONELINE="$(_strip_key_from_title "$TITLE_ONELINE" "$STORY_KEY_VAL")"

# Trim leading/trailing whitespace after stripping.
TITLE_ONELINE="$(printf '%s' "$TITLE_ONELINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

# If the title is now empty (it was nothing but the key), refuse.
if [ -z "$TITLE_ONELINE" ]; then
  die_parse "title is empty after stripping the story key — provide a meaningful title"
fi

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
if [ -n "$SCOPE" ]; then
  SUBJECT="$(printf '%s(%s): %s' "$PREFIX" "$SCOPE" "$SUBJECT_BODY")"
else
  SUBJECT="$(printf '%s: %s' "$PREFIX" "$SUBJECT_BODY")"
fi
if [ "${#SUBJECT}" -gt 72 ]; then
  SUBJECT="${SUBJECT:0:72}"
fi

# --- Emit ----------------------------------------------------------------
#
# Subject line + blank line + Story: body line.
printf '%s\n\nStory: %s\n' "$SUBJECT" "$STORY_KEY_VAL"

exit 0
