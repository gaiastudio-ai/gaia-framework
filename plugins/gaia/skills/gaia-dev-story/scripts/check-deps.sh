#!/usr/bin/env bash
# check-deps.sh — gaia-dev-story Step 1 dependency check (E57-S6, P1-1)
#
# Validates that every story listed in the input story's `depends_on:`
# frontmatter is in `status: done`. Three deterministic exit codes:
#
#   0 — all deps resolve to a story file AND all are status: done.
#       Stderr is silent.
#   1 — every dep file exists, but at least one is not status: done.
#       Stderr lists each offending dep as "<KEY>: <STATUS>" (one per line).
#   2 — at least one dep references a story file that does NOT exist on
#       disk. Stderr names the missing key (and the implementation-artifacts
#       directory searched). Exit 2 takes precedence over exit 1 — the
#       missing-file pass runs first and short-circuits.
#
# Usage:
#   check-deps.sh <story_path>
#
# Consumes the canonical env-var contract from story-parse.sh (E57-S5):
# the input story's `DEPENDS_ON` and `STORY_PATH` come from a forked
# story-parse evaluation. For each dep KEY we then locate its story file
# under "${IMPLEMENTATION_ARTIFACTS_DIR:-docs/implementation-artifacts}"
# matching the glob "<KEY>-*.md".
#
# Refs: FR-DSS-4, AF-2026-04-28-6, TC-DSS-05
# Story: E57-S6

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/check-deps.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; exit 64; }  # 64 = EX_USAGE; reserved exits 0/1/2 for verdicts

# --- Arg validation -------------------------------------------------------

if [ $# -lt 1 ]; then
  die_usage "usage: check-deps.sh <story_path>"
fi

STORY_PATH_INPUT="$1"

if [ ! -f "$STORY_PATH_INPUT" ]; then
  die_usage "story file not found: $STORY_PATH_INPUT"
fi

# Resolve story-parse.sh — same dir as this script.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
STORY_PARSE="$SELF_DIR/story-parse.sh"

if [ ! -x "$STORY_PARSE" ] && [ ! -f "$STORY_PARSE" ]; then
  die_usage "story-parse.sh not found at $STORY_PARSE"
fi

# Implementation-artifacts directory.
#
# E57-S14 / AI-RETRO-S45-3 / AC1-AC3: when no explicit env-var is set, walk
# UP from the input story path to find the parent `docs/implementation-artifacts/`
# directory and use that as the search root. This lets `check-deps.sh` see
# stories across other epics (nested layout: `epic-*/stories/`) — not just the
# one epic the input story happens to live in.
#
# Backward-compat: when `IMPLEMENTATION_ARTIFACTS_DIR` is set explicitly,
# use it verbatim — no walk-up, no recursion. Preserves test fixtures and
# any caller that intentionally constrains the search.
if [ -n "${IMPLEMENTATION_ARTIFACTS_DIR:-}" ]; then
  IMPL_DIR="$IMPLEMENTATION_ARTIFACTS_DIR"
else
  # Walk up from the input story's directory looking for `implementation-artifacts`.
  walk="$(cd "$(dirname "$STORY_PATH_INPUT")" && pwd)"
  IMPL_DIR=""
  while [ "$walk" != "/" ]; do
    if [ "$(basename "$walk")" = "implementation-artifacts" ]; then
      IMPL_DIR="$walk"
      break
    fi
    walk="$(dirname "$walk")"
  done
  # Fallback to the legacy `dirname $STORY_PATH_INPUT` shape if the walk-up
  # finds no `implementation-artifacts` ancestor — covers brownfield projects
  # and ad-hoc test fixtures.
  if [ -z "$IMPL_DIR" ]; then
    IMPL_DIR="$(dirname "$STORY_PATH_INPUT")"
  fi
fi

# --- Parse the input story to extract DEPENDS_ON --------------------------

# story-parse.sh emits KEY='value' lines. Eval into the local shell.
PARSE_OUTPUT="$(bash "$STORY_PARSE" "$STORY_PATH_INPUT")" || die_usage "story-parse.sh failed for $STORY_PATH_INPUT"
eval "$PARSE_OUTPUT"

# DEPENDS_ON is comma-joined or empty.
if [ -z "${DEPENDS_ON:-}" ]; then
  exit 0
fi

# Split DEPENDS_ON on commas into an array.
IFS=',' read -r -a DEP_KEYS <<< "$DEPENDS_ON"

# --- Pass 1: file-existence check (exit 2 takes precedence) ---------------

MISSING=""
declare -a DEP_FILES
for key in "${DEP_KEYS[@]}"; do
  # Trim whitespace.
  key="${key# }"; key="${key% }"
  [ -z "$key" ] && continue

  # Locate "<KEY>-*.md" under IMPL_DIR. Prefer first lexicographic match.
  # Searches both flat layout and epic-grouped layout (epic-*/stories/).
  match=""
  if [ -d "$IMPL_DIR" ]; then
    for cand in "$IMPL_DIR/${key}-"*.md "$IMPL_DIR"/epic-*/stories/"${key}-"*.md; do
      if [ -f "$cand" ]; then
        match="$cand"
        break
      fi
    done
  fi

  if [ -z "$match" ]; then
    if [ -z "$MISSING" ]; then
      MISSING="$key"
    else
      MISSING="$MISSING $key"
    fi
  fi
  DEP_FILES+=("${key}|${match}")
done

if [ -n "$MISSING" ]; then
  log "missing dependency story file(s) under $IMPL_DIR:"
  for k in $MISSING; do
    log "  ${k}: no file matching '${IMPL_DIR}/${k}-*.md'"
  done
  exit 2
fi

# --- Pass 2: status check ------------------------------------------------

OFFENDING=""
for entry in "${DEP_FILES[@]}"; do
  key="${entry%%|*}"
  file="${entry#*|}"
  [ -z "$file" ] && continue

  # Re-use story-parse.sh to read STATUS from the dep file. Exit non-zero
  # from story-parse means the dep file is malformed — surface as exit 1
  # with explanatory stderr (caller treats malformed dep as "not done").
  dep_parse=""
  if ! dep_parse="$(bash "$STORY_PARSE" "$file" 2>/dev/null)"; then
    OFFENDING="${OFFENDING}${key}: <unparseable>\n"
    continue
  fi
  # Eval in a subshell so dep STATUS does not leak into our env.
  dep_status="$(eval "$dep_parse"; printf '%s' "${STATUS:-}")"

  if [ "$dep_status" != "done" ]; then
    OFFENDING="${OFFENDING}${key}: ${dep_status}\n"
  fi
done

if [ -n "$OFFENDING" ]; then
  log "dependencies not in status: done"
  # shellcheck disable=SC2059
  printf "$OFFENDING" | while IFS= read -r line; do
    [ -n "$line" ] && log "  $line"
  done
  exit 1
fi

exit 0
