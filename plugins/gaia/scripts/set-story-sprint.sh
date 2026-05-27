#!/usr/bin/env bash
# set-story-sprint.sh — sanctioned setter for a story's `sprint_id` frontmatter.
#
# Test05 F-034. Story `status` has a sanctioned writer (transition-story-status.sh),
# but `sprint_id` did not — sprint planning had to hand-edit story frontmatter,
# which conflicts with the "no direct frontmatter edits" hygiene rule and is the
# field that `sprint-state.sh inject`'s drift guard READS (frontmatter sprint_id
# MUST equal yaml sprint_id before inject succeeds). This helper is the single
# sanctioned way to set it.
#
# Scope: rewrites ONLY the `sprint_id:` scalar in the story-file frontmatter
# (inserts it after `status:` if absent), atomically (tmp + mv) under the shared
# story-status flock so it serialises against transition-story-status.sh. It does
# NOT touch sprint-status.yaml (that surface is owned by sprint-state.sh inject)
# or the story `status` (owned by transition-story-status.sh).
#
# Usage:
#   set-story-sprint.sh <story_key> --sprint <sprint-id|null>
#   set-story-sprint.sh --help
#
# Exit codes:
#   0 — sprint_id set (or already equal — idempotent no-op)
#   1 — usage / arg error
#   2 — story file not found / unresolvable
#   6 — lock contention

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="set-story-sprint.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { err "$*"; exit "${2:-1}"; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
set-story-sprint.sh — set a story's sprint_id frontmatter field (sanctioned writer)

Usage:
  set-story-sprint.sh <story_key> --sprint <sprint-id|null>

Sets the `sprint_id:` scalar in the story-file frontmatter under the shared
story-status flock. Use `--sprint null` to clear (roll a story back to backlog).
Does NOT touch sprint-status.yaml (owned by sprint-state.sh inject) or `status:`
(owned by transition-story-status.sh).
USAGE
  exit 0
fi

STORY_KEY=""
SPRINT_ID="__UNSET__"
while [ $# -gt 0 ]; do
  case "$1" in
    --sprint) [ $# -ge 2 ] || die "--sprint requires a value"; SPRINT_ID="$2"; shift 2 ;;
    -h|--help) exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$STORY_KEY" ] || die "unexpected extra argument: $1"; STORY_KEY="$1"; shift ;;
  esac
done

[ -n "$STORY_KEY" ] || die "usage: set-story-sprint.sh <story_key> --sprint <sprint-id|null>"
[ "$SPRINT_ID" != "__UNSET__" ] || die "--sprint <sprint-id|null> is required"

# Resolve the story file via the shared layout-aware resolver (E105-S1 tier-0
# new layout, legacy nested, legacy flat).
RESOLVER="$SCRIPT_DIR/resolve-story-file.sh"
[ -x "$RESOLVER" ] || die "resolver missing or non-executable: $RESOLVER"
STORY_FILE="$("$RESOLVER" "$STORY_KEY")" || die "story file not found for key '$STORY_KEY'" 2
[ -f "$STORY_FILE" ] || die "resolved story file does not exist: $STORY_FILE" 2

# Normalise the value: bareword `null` is written unquoted; any other value is
# quoted. Mirrors the story-template convention (sprint_id: null | "sprint-N").
if [ "$SPRINT_ID" = "null" ]; then
  NEW_LINE='sprint_id: null'
else
  NEW_LINE="sprint_id: \"${SPRINT_ID}\""
fi

# Shared lock: serialise against transition-story-status.sh (same lock path).
MEMORY_PATH="${MEMORY_PATH:-${PROJECT_PATH:-.}/.gaia/memory}"
STORY_STATUS_LOCK="${STORY_STATUS_LOCK:-${MEMORY_PATH}/.story-status.lock}"
mkdir -p "$(dirname "$STORY_STATUS_LOCK")"
exec 200>"$STORY_STATUS_LOCK"
if command -v flock >/dev/null 2>&1; then
  flock -w 5 200 || die "lock contention on '$STORY_STATUS_LOCK' (5s timeout) — retry shortly" 6
fi

# Rewrite (or insert) the sprint_id line inside the frontmatter block only.
# awk state machine: fm=0 before first ---, fm=1 inside, fm=2 after close.
tmp="$(mktemp "${STORY_FILE}.XXXXXX")"
trap 'rm -f "$tmp" 2>/dev/null || true' EXIT
awk -v newline="$NEW_LINE" '
  BEGIN { fm = 0; done = 0 }
  /^---[[:space:]]*$/ {
    if (fm == 0) { fm = 1; print; next }
    if (fm == 1) {
      # closing frontmatter fence: if we never saw a sprint_id line, insert one
      # just before the close so the field always exists after this runs.
      if (!done) { print newline; done = 1 }
      fm = 2; print; next
    }
  }
  fm == 1 && /^sprint_id:[[:space:]]*/ && !done {
    print newline; done = 1; next
  }
  { print }
' "$STORY_FILE" > "$tmp"

# Sanity: the result must still have a frontmatter block + the new line.
grep -q "^${NEW_LINE}$" "$tmp" || die "rewrite produced no sprint_id line — aborting (story file unchanged)"

mv "$tmp" "$STORY_FILE"
trap - EXIT
printf '%s: %s sprint_id set to %s\n' "$SCRIPT_NAME" "$STORY_KEY" "$SPRINT_ID"
