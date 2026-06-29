#!/usr/bin/env bash
# cross-retro-detect.sh — scan prior retrospective-*.md files for recurring
# themes and escalate systemic ones by incrementing escalation_count in
# action-items.yaml.
#
# Usage:
#   cross-retro-detect.sh --retros-dir <dir> --action-items <path> --current-sprint <id>
#
# Behavior (architecture §10.28.3):
#   1. Glob retrospective-*.md under the given directory.
#   2. Extract action items from each retro's "## Action Items" section.
#   3. Normalize each line (lowercase + trim) and compute SHA-256(norm).
#   4. Flag any theme seen in 2+ distinct sprint_ids as systemic.
#   5. For each systemic theme: delegate to action-items-increment.sh using
#      (sprint_id=current_sprint, theme_hash) so a given current-sprint run is
#      idempotent per (sprint_id, theme_hash).
#
# Failure posture (per story: NON-BLOCKING):
#   * Missing action-items.yaml → warn and continue, no escalation.
#   * Zero prior retros                  → exit 0 with no output.
#   * Orphan AI-{n} reference            → log and continue.
#   * Empty / zero-byte retro file       → treat as zero themes.
#   * Malformed YAML in action-items.yaml → warn on increment failure, continue.

set -euo pipefail

RETROS_DIR=""
AI_FILE=""
CURRENT_SPRINT=""
MAX_BYTES=65536    # bounded per-file read

while [ $# -gt 0 ]; do
  case "$1" in
    --retros-dir)     RETROS_DIR="$2"; shift 2 ;;
    --action-items)   AI_FILE="$2"; shift 2 ;;
    --current-sprint) CURRENT_SPRINT="$2"; shift 2 ;;
    *) echo "error: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$RETROS_DIR" ] || [ -z "$CURRENT_SPRINT" ]; then
  echo "usage: $0 --retros-dir <dir> --action-items <path> --current-sprint <id>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INCREMENT="$SCRIPT_DIR/action-items-increment.sh"
THEME_HASH_BIN="$SCRIPT_DIR/theme-hash.sh"

# Canonical theme-hash: delegates to theme-hash.sh so every retro consumer
# hashes identically (architecture.md §10.28.3).
theme_hash() {
  "$THEME_HASH_BIN" "$1"
}

# Extract the literal sprint_id value from a retro file's YAML frontmatter.
# Falls back to the filename component (retrospective-<id>.md) when absent.
extract_sprint_id() {
  local file="$1" id=""
  id="$(awk '/^sprint_id:/ { gsub(/"/, "", $2); print $2; exit }' "$file" 2>/dev/null || true)"
  if [ -z "$id" ]; then
    id="$(basename "$file" | sed -E 's/^retrospective-//; s/\.md$//; s/-[0-9]{4}-[0-9]{2}-[0-9]{2}.*$//')"
  fi
  printf '%s' "$id"
}

# Extract bulleted action-item lines under a "## Action Items" section,
# stripping the leading "- " bullet and any trailing whitespace. Bounded read.
extract_action_items() {
  local file="$1"
  [ -s "$file" ] || return 0
  head -c "$MAX_BYTES" "$file" | awk '
    /^## Action Items[[:space:]]*$/ { in_section = 1; next }
    /^## /                          { in_section = 0 }
    in_section && /^-[[:space:]]/   {
      sub(/^-[[:space:]]+/, "", $0); print
    }
  '
}

# Build the cross-sprint theme map in a temporary workspace. Each line in
# THEMES is "sprint_id|theme_hash|raw_text".
WORK="$(mktemp -d -t cross-retro.XXXXXX)"
THEMES="$WORK/themes.tsv"
: > "$THEMES"

# Gather prior retros from BOTH the canonical nested `retrospective/` subdir
# (where /gaia-retro Step 6 writes them) AND the legacy flat location directly
# under RETROS_DIR (older projects). The previous single-level glob matched
# only the flat form, so once retros landed in the subdir the scan matched
# ZERO files and the systemic-theme / escalation_count mechanism silently
# no-op'd. Collect both, then de-duplicate by realpath so a retro reachable
# from both patterns is processed once.
shopt -s nullglob
_retro_candidates=(
  "$RETROS_DIR"/retrospective-*.md
  "$RETROS_DIR"/retrospective/retrospective-*.md
)
shopt -u nullglob

retros=()
_seen_retros=""
for _r in "${_retro_candidates[@]}"; do
  _rp="$(cd "$(dirname "$_r")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$_r")")"
  [ -n "$_rp" ] || _rp="$_r"
  case "$_seen_retros" in
    *"|$_rp|"*) continue ;;
  esac
  _seen_retros="${_seen_retros}|$_rp|"
  retros+=("$_r")
done

if [ "${#retros[@]}" -eq 0 ]; then
  # No prior retros — success with zero escalations.
  rm -rf "$WORK"
  exit 0
fi

for retro in "${retros[@]}"; do
  sprint_id="$(extract_sprint_id "$retro")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Silently tolerate AI-{n} references; log orphans to stderr.
    if printf '%s' "$line" | grep -qE '^AI-[0-9]+'; then
      ai_id="$(printf '%s' "$line" | awk '{print $1}' | sed 's/:.*//')"
      if [ -n "$AI_FILE" ] && [ -f "$AI_FILE" ]; then
        if ! grep -qE "id:[[:space:]]*${ai_id}\b" "$AI_FILE"; then
          echo "warn: orphan ${ai_id} referenced in ${retro} — skipping" >&2
          continue
        fi
      fi
    fi
    h="$(theme_hash "$line")"
    printf '%s\t%s\t%s\n' "$sprint_id" "$h" "$line" >> "$THEMES"
  done < <(extract_action_items "$retro")
done

# Systemic detection: hashes that appear in 2+ distinct sprint_ids.
SYSTEMIC="$WORK/systemic.txt"
awk -F'\t' '
  { key = $2; sprints[key] = sprints[key] ? sprints[key] SUBSEP $1 : $1 }
  END {
    for (k in sprints) {
      n = split(sprints[k], arr, SUBSEP)
      delete seen
      distinct = 0
      for (i = 1; i <= n; i++) {
        if (!(arr[i] in seen)) { seen[arr[i]] = 1; distinct++ }
      }
      if (distinct >= 2) print k
    }
  }
' "$THEMES" | sort -u > "$SYSTEMIC"

if [ -s "$SYSTEMIC" ]; then
  echo "systemic themes detected: $(wc -l < "$SYSTEMIC" | awk '{print $1}')"
fi

# Escalate each systemic theme exactly once per (current_sprint, theme_hash).
if [ -s "$SYSTEMIC" ]; then
  if [ -z "$AI_FILE" ] || [ ! -f "$AI_FILE" ]; then
    echo "warn: action-items.yaml not available — skipping escalations" >&2
  else
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      if ! "$INCREMENT" --file "$AI_FILE" --theme-hash "$h" --sprint-id "$CURRENT_SPRINT"; then
        echo "warn: increment failed for hash $h — continuing" >&2
      fi
    done < "$SYSTEMIC"
  fi
fi

rm -rf "$WORK"
exit 0
