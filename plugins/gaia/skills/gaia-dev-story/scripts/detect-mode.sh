#!/usr/bin/env bash
# detect-mode.sh — gaia-dev-story Step 1 mode detector
#
# Returns one of FRESH | REWORK | RESUME based on story status and the
# Review Gate table contents. Replaces LLM-based mode detection in
# /gaia-dev-story Step 1.
#
# Usage:
#   detect-mode.sh <story_path>
#
# Decision tree (deterministic, exactly 3 branches):
#   1. status == ready-for-dev                                  -> FRESH
#   2. status == in-progress AND Review Gate has FAILED row    -> REWORK
#   3. otherwise                                                -> RESUME
#
# Exit codes:
#   0 — success; one of FRESH | REWORK | RESUME on stdout
#   1 — usage error / missing file / malformed frontmatter

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/detect-mode.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# --- Arg validation -------------------------------------------------------

if [ $# -lt 1 ]; then
  die "usage: detect-mode.sh <story_path>"
fi

STORY_PATH_INPUT="$1"

# Path traversal rejection
case "$STORY_PATH_INPUT" in
  *..*) die "path traversal rejected: $STORY_PATH_INPUT" ;;
esac

if [ ! -f "$STORY_PATH_INPUT" ]; then
  die "story file not found: $STORY_PATH_INPUT"
fi

# --- Read status from frontmatter ----------------------------------------

STATUS_VAL="$(awk '
  BEGIN { state = 0 }
  state == 0 && $0 == "---" { state = 1; next }
  state == 1 && $0 == "---" { exit }
  state == 1 {
    if (match($0, /^[[:space:]]*status[[:space:]]*:[[:space:]]*/)) {
      v = substr($0, RSTART + RLENGTH)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      print v
      exit
    }
  }
' "$STORY_PATH_INPUT")"

if [ -z "$STATUS_VAL" ]; then
  die "could not read status from frontmatter: $STORY_PATH_INPUT"
fi

# --- Decision tree --------------------------------------------------------

case "$STATUS_VAL" in
  backlog|ready-for-dev)
    # A backlog story (no implementation, no checkpoint, no commits) is
    # canonically FRESH — same classification as ready-for-dev. Previously
    # fell through to the `*)` catchall and was misclassified as RESUME,
    # which steered /gaia-dev-story Step 1 into the
    # resume-an-in-flight-implementation branch for a never-started story.
    # The two backlog/ready-for-dev states cover "haven't started yet" — both
    # are FRESH; in-progress is the only state that can be REWORK or RESUME.
    printf 'FRESH\n'
    exit 0
    ;;
  in-progress)
    # Scan Review Gate table for any FAILED verdict. The gate table lives
    # under the "## Review Gate" heading; rows are pipe-delimited markdown
    # with the verdict in the second column.
    if awk '
      BEGIN { in_gate = 0 }
      $0 == "## Review Gate" { in_gate = 1; next }
      in_gate && /^## / { in_gate = 0 }
      in_gate && /\| FAILED \|/ { print "yes"; exit }
    ' "$STORY_PATH_INPUT" | grep -q yes; then
      printf 'REWORK\n'
    else
      printf 'RESUME\n'
    fi
    exit 0
    ;;
  *)
    printf 'RESUME\n'
    exit 0
    ;;
esac
