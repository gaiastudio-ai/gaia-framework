#!/usr/bin/env bash
# resolve-test-artifact-per-story.sh — resolve per-story test artifacts
# (atdd, test-automate-plan) to the §7.3 / Test03 mirror-symmetry layout.
#
# Background (AF-2026-05-30-1 / Test03 §7.3 second drift):
#   The §7.3 consolidated layout mandates that test-artifacts mirror
#   implementation-artifacts symmetrically — both grouped under
#   per-epic/per-story directories so a story's atdd + qa-tests +
#   test-automation + test-review live in ONE place, not scattered
#   across per-type subdirs. Pre-AF-30-1 the producers wrote flat:
#     .gaia/artifacts/test-artifacts/atdd-{story_key}.md
#     .gaia/artifacts/test-artifacts/test-automate-plan-{story_key}.md
#   AF-30-1 adds the canonical mirror home:
#     .gaia/artifacts/test-artifacts/epic-{epic_slug}/stories/{key}-{slug}/{type}.md
#
# This script mirrors plugins/gaia/scripts/resolve-story-file.sh — same
# directory-naming convention (epic-{slug}/stories/{key}-{slug}/) and same
# read-side dual-path precedence so existing flat artifacts keep resolving
# until /gaia-migrate v1 v2 (or the AF-30-1 migration helper) ports them.
#
# Resolution order (read side):
#   0. New per-story mirror:
#        .gaia/artifacts/test-artifacts/epic-{epic_slug}/stories/{key}-{slug}/{type}.md
#      Highest precedence. New writes go here.
#   1. Legacy flat (read-only fallback):
#        .gaia/artifacts/test-artifacts/{type}-{key}.md
#      Existing artifacts continue to resolve; never migrated implicitly.
#
# Write-path resolution: callers ask for the NEW canonical write path via
# `--write` (returns rung 0). Without `--write`, read-side precedence applies
# (rung 0 first, then rung 1).
#
# Usage:
#   resolve-test-artifact-per-story.sh <type> <story_key> [--write] [--existing-only]
#
#   <type>             one of: atdd | test-automate-plan
#   <story_key>        e.g. E105-S1
#   --write            print the rung-0 (new canonical) path even if it does
#                      not exist on disk; create parent dirs.
#   --existing-only    print rung-0 if it exists; else rung-1 if it exists;
#                      else exit 1 with no stdout (matches the contract
#                      established by resolve-artifact-path.sh).
#
# Exit codes:
#   0 — resolved (stdout = path; on --write, also mkdir -p the parent dir)
#   1 — story key unresolvable, type invalid, or --existing-only and no rung
#       exists.

set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: resolve-test-artifact-per-story.sh <type> <story_key> [--write] [--existing-only]
  <type>            atdd | test-automate-plan
  <story_key>       e.g. E105-S1
  --write           print/prepare the rung-0 (new canonical) write path
  --existing-only   print the first existing rung; exit 1 if none
EOF
  exit 1
}

[ $# -ge 2 ] || usage
TYPE="$1"
STORY_KEY="$2"
shift 2

WRITE=0
EXISTING_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --write)           WRITE=1; shift ;;
    --existing-only)   EXISTING_ONLY=1; shift ;;
    *) usage ;;
  esac
done

case "$TYPE" in
  atdd|test-automate-plan) ;;
  *)
    echo "resolve-test-artifact-per-story: unknown type '$TYPE' (expected: atdd | test-automate-plan)" >&2
    exit 1
    ;;
esac

PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$PWD}}}"
TEST_ARTIFACTS_DIR="${TEST_ARTIFACTS:-${PROJECT_ROOT}/.gaia/artifacts/test-artifacts}"
IMPL_ARTIFACTS_DIR="${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts}"

# Resolve the story's epic + story slug by inspecting the implementation
# tree (same naming the per-story story.md uses). When the story has no
# per-story layout dir yet, we synthesise the mirror path using just the
# story key — falls back to `epic-{epic_id}/stories/{story_key}/` and
# accepts a later rename when the story dir is created.

EPIC_DIR=""
STORY_DIR_NAME=""
if [ -d "$IMPL_ARTIFACTS_DIR" ]; then
  # Find epic-X dir containing stories/{STORY_KEY}-* with strict prefix-boundary
  # match (so E1-S2 never matches E1-S21-*).
  match=$(find "$IMPL_ARTIFACTS_DIR" -type d -path "*/epic-*/stories/${STORY_KEY}-*" 2>/dev/null | head -1 || true)
  if [ -n "$match" ]; then
    STORY_DIR_NAME=$(basename "$match")
    # Validate STORY_KEY- prefix boundary (resolve-story-file.sh §Tier 0 idiom)
    case "$STORY_DIR_NAME" in
      "${STORY_KEY}-"*)
        EPIC_DIR_PATH=$(dirname "$(dirname "$match")")
        EPIC_DIR=$(basename "$EPIC_DIR_PATH")
        ;;
      *) STORY_DIR_NAME="" ;;
    esac
  fi
fi

# Fallback when no story dir exists yet: extract epic_id from the story key
# (E1-S1 → E1) and use the bare key as the story-dir name. The producer that
# calls this later will be writing INTO this dir; a subsequent rename to the
# canonical {key}-{slug} form is honored by rung-0 resolution above.
if [ -z "$EPIC_DIR" ]; then
  EPIC_ID="${STORY_KEY%%-*}"
  EPIC_DIR="epic-${EPIC_ID}"
fi
if [ -z "$STORY_DIR_NAME" ]; then
  STORY_DIR_NAME="$STORY_KEY"
fi

NEW_DIR="${TEST_ARTIFACTS_DIR}/${EPIC_DIR}/stories/${STORY_DIR_NAME}"
NEW_PATH="${NEW_DIR}/${TYPE}.md"
LEGACY_PATH="${TEST_ARTIFACTS_DIR}/${TYPE}-${STORY_KEY}.md"

if [ "$WRITE" -eq 1 ]; then
  mkdir -p "$NEW_DIR"
  printf '%s\n' "$NEW_PATH"
  exit 0
fi

# Read-side precedence: rung 0 first, then rung 1.
if [ -f "$NEW_PATH" ]; then
  printf '%s\n' "$NEW_PATH"
  exit 0
fi
if [ -f "$LEGACY_PATH" ]; then
  printf '%s\n' "$LEGACY_PATH"
  exit 0
fi

if [ "$EXISTING_ONLY" -eq 1 ]; then
  exit 1
fi

# Neither exists — print the expected (rung 0) path for error messages.
printf '%s\n' "$NEW_PATH"
exit 0
