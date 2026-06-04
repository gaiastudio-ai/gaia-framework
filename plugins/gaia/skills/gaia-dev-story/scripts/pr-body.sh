#!/usr/bin/env bash
# pr-body.sh — gaia-dev-story Step 11 PR-body helper (E57-S7, P1-2)
#
# Reads a story file's YAML frontmatter and Acceptance-Criteria section, runs
# dod-check.sh for a Definition-of-Done summary, captures `git diff --stat`,
# and emits a Markdown PR body with exactly four canonical sections in order:
#   1. Acceptance Criteria   (one bullet per AC, copied from frontmatter)
#   2. Definition of Done    (parsed from dod-check.sh output)
#   3. Diff Stat             (`git diff --stat` block, fenced)
#   4. Story:                (relative link to the story file under docs/)
#
# Refs: FR-DSS-5, FR-DSS-6, NFR-DSS-1, AF-2026-04-28-6
# Story: E57-S7
# Traces: TC-DSS-06 (four sections), TC-DSS-08 (shell-metachar safety)
#
# Usage:
#   pr-body.sh <story_path>
#
# Hard rules (per CLAUDE.md):
#   - The shell-builtin string-execution primitive is banned outright. All
#     user-controlled values flow through `printf '%s'`.
#   - No `Claude` / `AI` / `Co-Authored-By` strings emitted.
#
# Exit codes:
#   0 — success; PR body printed on stdout.
#   1 — usage error / missing file.
#   2 — malformed frontmatter / missing required field.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/pr-body.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; exit 1; }
die_parse() { log "$*"; exit 2; }

# --- Arg validation -------------------------------------------------------

if [ $# -lt 1 ]; then
  die_usage "usage: pr-body.sh <story_path> [--allow-stub-reason <reason>]"
fi

STORY_PATH_INPUT="$1"
shift

# --- Optional --allow-stub-reason flag (E88-S3, FR-DPD-3) -----------------
# When present, emit a fifth canonical section `## Allow-stub override`
# alongside the four existing sections. Forwarded by /gaia-dev-story Step
# 11 from the Step 11a forbidden-sentinel-scan.sh accepted reason. Empty
# value disables the section.
ALLOW_STUB_REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-stub-reason)
      [ $# -ge 2 ] || die_usage "--allow-stub-reason requires a value"
      ALLOW_STUB_REASON="$2"
      shift 2
      ;;
    --allow-stub-reason=*)
      ALLOW_STUB_REASON="${1#*=}"
      shift
      ;;
    *)
      die_usage "unknown flag: $1"
      ;;
  esac
done

case "$STORY_PATH_INPUT" in
  *..*) die_usage "path traversal rejected: $STORY_PATH_INPUT" ;;
esac

if [ ! -f "$STORY_PATH_INPUT" ]; then
  die_usage "story file not found: $STORY_PATH_INPUT"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOD_CHECK="$SCRIPT_DIR/dod-check.sh"

# --- Frontmatter extraction (shared via frontmatter-lib.sh, E64-S1 AC3) --

# shellcheck source=./frontmatter-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/frontmatter-lib.sh"

FRONTMATTER="$(fm_slice "$STORY_PATH_INPUT")" || die_parse "malformed frontmatter (unbalanced '---' markers): $STORY_PATH_INPUT"

get_field() {
  local key="$1"
  printf '%s\n' "$FRONTMATTER" | fm_get_field "$key"
}

# Tolerate the `story_key:` convention every other story-consuming skill
# accepts; canonical `key:` takes precedence (issue #1091).
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

if [ -z "$STORY_KEY_VAL" ]; then
  die_parse "missing required frontmatter field: key (or alias story_key)"
fi

# --- Acceptance Criteria extraction ---------------------------------------
#
# Pull every checklist line under the "## Acceptance Criteria" heading. The
# section ends at the next "## " heading. Lines beginning with `- [ ]` or
# `- [x]` are emitted verbatim minus the checkbox prefix; that text is
# user-controlled so it must flow through printf '%s'.

AC_LINES="$(awk '
  BEGIN { in_section = 0 }
  $0 == "## Acceptance Criteria" { in_section = 1; next }
  in_section && /^## / { in_section = 0 }
  in_section && /^[[:space:]]*-[[:space:]]+\[[ x]\]/ {
    # Strip leading "- [ ] " or "- [x] " prefix
    line = $0
    sub(/^[[:space:]]*-[[:space:]]+\[[ x]\][[:space:]]*/, "", line)
    print line
  }
' "$STORY_PATH_INPUT")"

# --- DoD summary ---------------------------------------------------------
#
# Run dod-check.sh and capture YAML rows. The script is allowed to exit
# non-zero (some checks may FAIL) — we still want the summary table.
DOD_OUTPUT=""
if [ -x "$DOD_CHECK" ]; then
  set +e
  DOD_OUTPUT="$(STORY_FILE="$STORY_PATH_INPUT" "$DOD_CHECK" 2>&1)"
  set -e
fi

# Parse YAML rows of the form:
#   - { item: <name>, status: PASSED|FAILED, output: ... }
# and emit a clean bullet list.
DOD_SUMMARY="$(printf '%s\n' "$DOD_OUTPUT" | awk '
  /^[[:space:]]*-[[:space:]]*\{[[:space:]]*item:/ {
    # Extract item value
    item = ""
    if (match($0, /item:[[:space:]]*[A-Za-z0-9_-]+/)) {
      tok = substr($0, RSTART, RLENGTH)
      sub(/^item:[[:space:]]*/, "", tok)
      item = tok
    }
    status = ""
    if (match($0, /status:[[:space:]]*[A-Z]+/)) {
      tok = substr($0, RSTART, RLENGTH)
      sub(/^status:[[:space:]]*/, "", tok)
      status = tok
    }
    if (item != "" && status != "") {
      printf "- %s: %s\n", item, status
    }
  }
')"

# --- git diff --stat ------------------------------------------------------
#
# Capture both staged and unstaged combined; ignore failures (no repo, etc.).
GIT_DIFF_STAT=""
set +e
GIT_DIFF_STAT="$(git diff --stat HEAD 2>/dev/null || git diff --stat 2>/dev/null)"
set -e

# --- Relative story link --------------------------------------------------
#
# Compute a path that starts at "docs/" if present in the input, otherwise
# fall back to the basename. This produces a stable link regardless of
# absolute-path invocation.
RELATIVE_LINK="$STORY_PATH_INPUT"
case "$STORY_PATH_INPUT" in
  *docs/*)
    # Strip everything up to and including the last "docs/" prefix's parent
    RELATIVE_LINK="docs/${STORY_PATH_INPUT#*docs/}"
    ;;
esac

# --- Emit Markdown PR body ------------------------------------------------
#
# Section ordering is locked by AC1 — do not reorder. Every user-controlled
# value flows through printf '%s'.
printf '## Acceptance Criteria\n\n'
if [ -n "$AC_LINES" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf -- '- '
    printf '%s' "$line"
    printf '\n'
  done <<EOF
$AC_LINES
EOF
else
  printf -- '- (none)\n'
fi
printf '\n'

printf '## Definition of Done\n\n'
if [ -n "$DOD_SUMMARY" ]; then
  printf '%s\n' "$DOD_SUMMARY"
else
  printf -- '- (no DoD output)\n'
fi
printf '\n'

printf '## Diff Stat\n\n'
printf '```\n'
if [ -n "$GIT_DIFF_STAT" ]; then
  printf '%s\n' "$GIT_DIFF_STAT"
else
  printf '(no staged or unstaged changes)\n'
fi
printf '```\n\n'

# --- Allow-stub override section (E88-S3) ---------------------------------
# Fifth canonical section, emitted only when --allow-stub-reason was passed.
# Per AC5 / FR-DPD-3 the reason is rendered verbatim under the heading.
if [ -n "$ALLOW_STUB_REASON" ]; then
  printf '## Allow-stub override\n\n'
  printf '%s\n\n' "$ALLOW_STUB_REASON"
fi

printf 'Story: [%s](%s)\n' "$STORY_KEY_VAL" "$RELATIVE_LINK"

exit 0
