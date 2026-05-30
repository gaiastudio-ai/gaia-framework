#!/usr/bin/env bash
# migrate-test-artifacts-to-per-story.sh — one-time migration helper for the
# AF-2026-05-30-1 / Test03 §7.3 test-artifacts mirror retrofit.
#
# Moves existing flat per-story test artifacts to the new mirror-symmetry
# layout under per-epic/per-story directories:
#
#   .gaia/artifacts/test-artifacts/atdd-{key}.md
#     → .gaia/artifacts/test-artifacts/epic-{epic_slug}/stories/{key}-{slug}/atdd.md
#
#   .gaia/artifacts/test-artifacts/test-automate-plan-{key}.md
#     → .gaia/artifacts/test-artifacts/epic-{epic_slug}/stories/{key}-{slug}/test-automate-plan.md
#
# Only files whose story key resolves to an existing implementation-artifacts
# per-story directory are moved (the canonical {epic_slug} + {story_slug}
# come from there). Files whose key cannot be resolved are left flat and
# logged — the producer skills accept either location on read during the
# migration window, so leaving stragglers does not break anything.
#
# Per CLAUDE.md mass-move policy, the helper ends with a
# `find <test-artifacts root> -type d -empty -delete` pass that prunes any
# emptied per-type subdirs (e.g. legacy `atdd/`, `test-automation/` that
# pre-dated the per-story shape) without touching the new per-epic tree.
#
# Usage:
#   migrate-test-artifacts-to-per-story.sh [--project-root <dir>] [--dry-run]
#
# Idempotent: a second run is a no-op (everything already moved).

set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$PWD}}"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "migrate-test-artifacts-to-per-story: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

TEST_ROOT="${PROJECT_ROOT}/.gaia/artifacts/test-artifacts"
IMPL_ROOT="${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts"

if [ ! -d "$TEST_ROOT" ]; then
  echo "migrate-test-artifacts-to-per-story: no test-artifacts/ at $TEST_ROOT — nothing to do"
  exit 0
fi
if [ ! -d "$IMPL_ROOT" ]; then
  echo "migrate-test-artifacts-to-per-story: no implementation-artifacts/ at $IMPL_ROOT — cannot resolve epic/story slugs" >&2
  exit 1
fi

# resolve_story_target <type> <story_key>
# Echoes the new canonical target path, or exits 1 if the story dir doesn't
# exist (cannot resolve {epic_slug} + {story_slug}).
resolve_story_target() {
  local type="$1"
  local key="$2"
  local match
  match=$(find "$IMPL_ROOT" -type d -path "*/epic-*/stories/${key}-*" 2>/dev/null | head -1 || true)
  if [ -z "$match" ]; then
    return 1
  fi
  local story_dir epic_dir
  story_dir=$(basename "$match")
  # Strict prefix-boundary guard (so E1-S2 doesn't match E1-S21-*)
  case "$story_dir" in
    "${key}-"*) ;;
    *) return 1 ;;
  esac
  epic_dir=$(basename "$(dirname "$(dirname "$match")")")
  printf '%s/%s/stories/%s/%s.md\n' "$TEST_ROOT" "$epic_dir" "$story_dir" "$type"
}

moved=0
skipped=0
stragglers=()

migrate_type() {
  local type="$1"
  local f
  # Match the flat form {type}-{key}.md at the test-artifacts top level
  # (NOT inside any subdir — that's already migrated or legacy per-type).
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local base key target
    base=$(basename "$f" .md)
    key="${base#${type}-}"
    # Sanity-check the key shape: E{n}-S{n}
    case "$key" in
      E[0-9]*-S[0-9]*) ;;
      *)
        echo "  skip (unparseable key): $f"
        skipped=$((skipped+1))
        continue
        ;;
    esac
    if ! target=$(resolve_story_target "$type" "$key"); then
      stragglers+=("$f")
      skipped=$((skipped+1))
      continue
    fi
    if [ -e "$target" ]; then
      echo "  skip (target exists): $f → $target"
      skipped=$((skipped+1))
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  would move: $f → $target"
    else
      mkdir -p "$(dirname "$target")"
      mv "$f" "$target"
      echo "  moved: $f → $target"
    fi
    moved=$((moved+1))
  done < <(find "$TEST_ROOT" -maxdepth 1 -type f -name "${type}-*.md" 2>/dev/null)
}

echo "migrate-test-artifacts-to-per-story: ${TEST_ROOT}"
echo "== atdd =="
migrate_type atdd
echo "== test-automate-plan =="
migrate_type test-automate-plan

# Prune emptied directories (per CLAUDE.md mass-move policy). Only touches
# truly empty dirs, so the new per-epic tree and any non-empty legacy
# per-type subdirs remain intact.
if [ "$DRY_RUN" -ne 1 ]; then
  find "$TEST_ROOT" -type d -empty -delete 2>/dev/null || true
fi

echo ""
echo "summary: moved=$moved skipped=$skipped stragglers=${#stragglers[@]}"
if [ "${#stragglers[@]}" -gt 0 ]; then
  echo ""
  echo "stragglers (story key did not resolve to an existing implementation-artifacts/ per-story dir):"
  for f in "${stragglers[@]}"; do
    printf '  - %s\n' "$f"
  done
  echo ""
  echo "stragglers remain at the flat path. Producer skills accept either location on read"
  echo "during the migration window — leaving these does not break anything. Move manually"
  echo "once the corresponding story dir exists under implementation-artifacts/."
fi
