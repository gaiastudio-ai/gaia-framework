#!/usr/bin/env bash
# priority-flag.sh — priority_flag read, scan, and clear operations.
#
# E38-S4: Provides public functions for reading and clearing the
# priority_flag frontmatter field on story files. Used by
# gaia-sprint-plan SKILL.md to auto-include flagged backlog stories
# and clear the flag after sprint finalization.
#
# Public functions:
#   pflag_read           <story_file>       — read priority_flag value
#   pflag_scan_backlog   <impl_dir>         — find flagged backlog stories
#   pflag_clear          <story_file>       — set priority_flag to null
#   pflag_record_cleared <yaml> <keys>      — append cleared keys to yaml
#
# Contract: NO set/write function. Humans set the flag via frontmatter
# edit. This script only reads and clears.
# Per: feedback_priority_flag_never_auto_set

set -euo pipefail
SCRIPT_NAME="${SCRIPT_NAME:-priority-flag.sh}"

# ---------------------------------------------------------------------------
# _pflag_fm_field — extract a YAML frontmatter field value (private helper)
#   $1 = field name (e.g. "priority_flag", "status", "key")
#   $2 = file path
# Prints the unquoted value. Exits at the closing --- fence.
# ---------------------------------------------------------------------------
_pflag_fm_field() {
  local field="$1" file="$2"
  awk -v fld="$field" '
    /^---$/  { fm++; next }
    fm == 1 && $0 ~ "^" fld ":" {
      sub("^" fld ":[[:space:]]*", "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      print
      exit
    }
    fm >= 2 { exit }
  ' "$file"
}

# ---------------------------------------------------------------------------
# pflag_read — read priority_flag value from story file YAML frontmatter
# ---------------------------------------------------------------------------
pflag_read() {
  _pflag_fm_field "priority_flag" "$1"
}

# ---------------------------------------------------------------------------
# pflag_scan_backlog — scan impl dir for backlog stories with next-sprint flag
#
# E79-S4: walks the canonical nested layout
#   docs/implementation-artifacts/epic-*/stories/**/*.md
# recursively, AND keeps a parallel non-recursive pass over the legacy flat
# layout so flat-path stories remain surfaced during the migration window
# (until E79-S6 backfill completes). Frontmatter parse failures are tolerated
# (best-effort, no exit-non-zero) so non-story .md files (e.g. README.md
# accidentally placed under stories/) are skipped silently.
# ---------------------------------------------------------------------------
pflag_scan_backlog() {
  local dir="$1"
  local f status_val flag_val key_val
  # Canonical nested layout — recursive walk under any epic-*/stories/ subtree.
  # `find … -path '*/stories/*.md'` is the canonical idiom (E79-S4); bash globs
  # do NOT recurse, so the previous `for f in "$dir"/*.md` only saw the legacy
  # flat layer.
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    status_val="$(_pflag_fm_field "status" "$f" 2>/dev/null || true)"
    [ "$status_val" = "backlog" ] || continue
    flag_val="$(pflag_read "$f" 2>/dev/null || true)"
    [ "$flag_val" = "next-sprint" ] || continue
    key_val="$(_pflag_fm_field "key" "$f" 2>/dev/null || true)"
    [ -n "$key_val" ] || continue
    printf '%s\n' "$key_val"
  done < <(find "$dir" -path '*/stories/*.md' -type f -print0 2>/dev/null)
  # Legacy flat layout — read-only fallback until E79-S6 migration completes.
  # Same flag-filter semantics; only the traversal scope differs.
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    status_val="$(_pflag_fm_field "status" "$f" 2>/dev/null || true)"
    [ "$status_val" = "backlog" ] || continue
    flag_val="$(pflag_read "$f" 2>/dev/null || true)"
    [ "$flag_val" = "next-sprint" ] || continue
    key_val="$(_pflag_fm_field "key" "$f" 2>/dev/null || true)"
    [ -n "$key_val" ] || continue
    printf '%s\n' "$key_val"
  done
}

# ---------------------------------------------------------------------------
# pflag_clear — rewrite priority_flag to null in a story file
# ---------------------------------------------------------------------------
pflag_clear() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf '%s: error: file not found: %s\n' "$SCRIPT_NAME" "$file" >&2
    return 1
  fi
  local current
  current="$(pflag_read "$file")"
  # No-op if already null or missing
  [ "$current" = "null" ] && return 0
  [ -z "$current" ] && return 0
  # Line-targeted rewrite — same pattern as status-sync
  local tmp="${file}.tmp.$$"
  awk '
    /^---$/  { fm++; print; next }
    fm == 1 && /^priority_flag:/ {
      print "priority_flag: null"
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# pflag_record_cleared — append priority_flag_cleared block to sprint yaml
# ---------------------------------------------------------------------------
pflag_record_cleared() {
  local yaml="$1"
  local keys="$2"
  if [ -z "$keys" ]; then
    printf '\npriority_flag_cleared: []\n' >> "$yaml"
    return 0
  fi
  printf '\npriority_flag_cleared:\n' >> "$yaml"
  local k
  for k in $keys; do
    printf '  - "%s"\n' "$k" >> "$yaml"
  done
}
