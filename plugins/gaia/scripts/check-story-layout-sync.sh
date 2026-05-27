#!/usr/bin/env bash
# check-story-layout-sync.sh — detect canonical-per-epic-layout drift.
#
# Story: E79-S5 — Static `monolith-shard-sync` extension — `story-layout-sync` advisory check.
# Trace: TC-CSP-7
#
# Mirrors the established `check-monolith-shard-sync.sh` advisory pattern.
# Walks .gaia/artifacts/implementation-artifacts/ and emits WARNING lines on stdout
# when story-file layout drift is detected. The script is ADVISORY: it
# always exits 0. CRITICAL severity is reserved for future hard-conflict
# cases (e.g., two per-epic stories sharing the same `key:` under different
# epics) — none of the three checks in this file ever emit CRITICAL.
#
# Drift classes (each is repairable by the E79-S6 migration script):
#
#   1. legacy-flat-path        — story file at docs/implementation-artifacts/
#                                 instead of .gaia/artifacts/implementation-artifacts/
#                                 epic-E{N}-{slug}/stories/
#   2. heterogeneous-story-index — both a flat .gaia/artifacts/implementation-artifacts/
#                                  story-index.yaml AND one or more per-epic
#                                  .gaia/artifacts/implementation-artifacts/epic-E*/
#                                  stories/story-index.yaml files exist.
#   3. epic-slug-mismatch      — per-epic story file's frontmatter `epic:`
#                                  field does not match the directory's
#                                  `epic-E{N}-{slug}` token.
#
# Line format (canonical):
#   {SEVERITY} story-layout-sync: {check-id} {detail-fields...}
#
# Always exits 0. Stdout-only on clean runs.

set -euo pipefail

# ---------------------------------------------------------------------------
# Args.
# ---------------------------------------------------------------------------

ROOT="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      shift
      ROOT="${1:-.}"
      shift
      ;;
    -h|--help)
      cat <<USAGE
Usage: check-story-layout-sync.sh [--root <project-root>]

Walk docs/implementation-artifacts/ and emit WARNING lines on stdout when
story-file layout drift is detected. Always exits 0 (advisory).

Drift classes:
  legacy-flat-path           — flat-path story files
  heterogeneous-story-index  — both flat and per-epic story-index.yaml present
  epic-slug-mismatch         — per-epic story frontmatter epic: != dir epic key

Line format:
  WARNING story-layout-sync: <check-id> <detail-fields...>
USAGE
      exit 0
      ;;
    *)
      printf 'check-story-layout-sync: unknown arg: %s\n' "$1" >&2
      exit 64
      ;;
  esac
done

# Resolve to absolute path so `cd` semantics inside helpers are stable.
if [[ -d "$ROOT" ]]; then
  ROOT="$(cd "$ROOT" && pwd)"
fi

# E96-S1 path resolution: prefer .gaia/artifacts/, fall back to legacy docs/
if [[ -d "$ROOT/.gaia/artifacts/implementation-artifacts" ]]; then
  IMPL_DIR_ABS="$ROOT/.gaia/artifacts/implementation-artifacts"
else
  IMPL_DIR_ABS="$ROOT/docs/implementation-artifacts"
fi

# Nothing to check if the implementation-artifacts dir does not exist.
if [[ ! -d "$IMPL_DIR_ABS" ]]; then
  exit 0
fi

# All emitted file paths are relative to $ROOT for stable, copy-pasteable
# output regardless of the caller's cwd.

# ---------------------------------------------------------------------------
# Check A — legacy flat-path stories.
#
# Emits one WARNING per file matching:
#   .gaia/artifacts/implementation-artifacts/E*-S*-*.md  (maxdepth 1)
# ---------------------------------------------------------------------------

check_legacy_flat_path() {
  # `find -maxdepth 1` so per-epic stories under epic-E*/stories/ are NOT
  # caught here. We sort for deterministic output.
  while IFS= read -r abs_path; do
    [[ -z "$abs_path" ]] && continue
    local rel
    rel="docs/implementation-artifacts/$(basename "$abs_path")"
    printf 'WARNING story-layout-sync: legacy-flat-path %s\n' "$rel"
  done < <(
    find "$IMPL_DIR_ABS" -maxdepth 1 -type f -name 'E*-S*-*.md' 2>/dev/null \
      | LC_ALL=C sort
  )
}

# ---------------------------------------------------------------------------
# Check B — heterogeneous story-index.
#
# Emits exactly ONE line if both
#   .gaia/artifacts/implementation-artifacts/story-index.yaml
# AND any per-epic story-index.yaml are present. Per-epic indexes are detected
# at BOTH layout locations (E105-S1 / ADR-127):
#   - legacy: epic-E*/stories/story-index.yaml  (depth 3)
#   - new:    epic-E*/story-index.yaml          (depth 2, epic root)
# The detail line names the flat-index path and the lexicographically first
# per-epic match across both locations.
# ---------------------------------------------------------------------------

check_heterogeneous_story_index() {
  local flat_index="$IMPL_DIR_ABS/story-index.yaml"
  if [[ ! -f "$flat_index" ]]; then
    return 0
  fi

  local first_per_epic
  first_per_epic="$(
    {
      # Legacy per-epic index under stories/ (depth 3).
      find "$IMPL_DIR_ABS" \
        -mindepth 3 -maxdepth 3 \
        -type f -name 'story-index.yaml' \
        -path "$IMPL_DIR_ABS/epic-E*/stories/story-index.yaml" \
        2>/dev/null
      # New per-epic index at the epic root (depth 2, E105-S1 / ADR-127).
      find "$IMPL_DIR_ABS" \
        -mindepth 2 -maxdepth 2 \
        -type f -name 'story-index.yaml' \
        -path "$IMPL_DIR_ABS/epic-E*/story-index.yaml" \
        2>/dev/null
    } \
      | LC_ALL=C sort \
      | head -n1
  )"

  if [[ -z "$first_per_epic" ]]; then
    return 0
  fi

  local flat_rel="docs/implementation-artifacts/story-index.yaml"
  local first_rel
  first_rel="${first_per_epic#"$ROOT/"}"

  printf 'WARNING story-layout-sync: heterogeneous-story-index %s %s\n' \
    "$flat_rel" "$first_rel"
}

# ---------------------------------------------------------------------------
# Check C — epic-slug mismatch.
#
# For each per-epic story file at
#   .gaia/artifacts/implementation-artifacts/epic-E{N}-{slug}/stories/{key}-{slug}.md
# read its frontmatter `epic:` field and compare against the directory's
# `epic-E{N}` token. Emit a WARNING on mismatch.
# ---------------------------------------------------------------------------

# Extract the value of the `epic:` field from a story's YAML frontmatter.
# Reads the first frontmatter block (between the first two `---` lines) and
# returns the unquoted value of the `epic:` key. Empty string if absent.
_read_epic_frontmatter() {
  local file="$1"
  awk '
    BEGIN { c = 0 }
    /^---[[:space:]]*$/ {
      c++
      if (c == 2) exit
      next
    }
    c == 1 && /^epic:[[:space:]]*/ {
      sub(/^epic:[[:space:]]*/, "")
      # Strip surrounding quotes.
      gsub(/^"|"$/, "")
      gsub(/^'\''|'\''$/, "")
      # Trim trailing whitespace.
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$file"
}

check_epic_slug_mismatch() {
  # Walk every per-epic stories/*.md file. We bound depth to keep the find
  # cheap and to avoid matching anything outside the canonical layout shape.
  while IFS= read -r abs_path; do
    [[ -z "$abs_path" ]] && continue

    local rel="${abs_path#"$ROOT/"}"
    local base
    base="$(basename "$abs_path")"

    # Skip auxiliary files (e.g., review summaries that landed under stories/).
    case "$base" in
      story-index.yaml) continue ;;
    esac

    # Derive the directory's epic key from the parent-of-parent directory name:
    #   .../.gaia/artifacts/implementation-artifacts/epic-E{N}-{slug}/stories/<file>
    local stories_dir epic_dir epic_dirname
    stories_dir="$(dirname "$abs_path")"
    epic_dir="$(dirname "$stories_dir")"
    epic_dirname="$(basename "$epic_dir")"

    # Match `epic-E{N}` prefix; epic key is `E{N}`.
    if [[ ! "$epic_dirname" =~ ^epic-(E[0-9]+)(-.*)?$ ]]; then
      continue
    fi
    local dir_epic_key="${BASH_REMATCH[1]}"

    local fm_epic
    fm_epic="$(_read_epic_frontmatter "$abs_path")"

    # No frontmatter `epic:` field — silent skip (out of scope here; the
    # advisory is intentionally conservative).
    [[ -z "$fm_epic" ]] && continue

    if [[ "$fm_epic" != "$dir_epic_key" ]]; then
      printf 'WARNING story-layout-sync: epic-slug-mismatch %s dir=%s fm=%s\n' \
        "$rel" "$dir_epic_key" "$fm_epic"
    fi
  done < <(
    find "$IMPL_DIR_ABS" \
      -mindepth 3 -maxdepth 3 \
      -type f -name '*.md' \
      -path "$IMPL_DIR_ABS/epic-E*/stories/*.md" \
      2>/dev/null \
      | LC_ALL=C sort
  )
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

check_legacy_flat_path
check_heterogeneous_story_index
check_epic_slug_mismatch

exit 0
