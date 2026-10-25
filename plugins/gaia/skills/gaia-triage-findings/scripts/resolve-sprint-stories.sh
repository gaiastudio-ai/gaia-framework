#!/usr/bin/env bash
# resolve-sprint-stories.sh — emit the set of story files /gaia-triage-findings
# should scan.
#
# DEFAULT (sprint-scoped): read the active sprint from sprint-status.yaml and
# emit the file paths of ONLY its committed stories. This is the token-budget /
# performance fix — historical stories from prior sprints have already been
# triaged and re-scanning them wastes context.
#
#   - The active sprint is read from the TOP-LEVEL `sprint_id:` key.
#   - The committed stories are read from the TOP-LEVEL `stories:` sequence
#     (each entry has a `key:`).
#   - Gating: the sprint must be in a runnable lifecycle state (`active` or
#     `review`) for sprint-scoped resolution to proceed. A `closed`/`planned`
#     sprint emits nothing with an informational message on stderr (the caller
#     decides whether to fall back to --all).
#
# --all (full historical sweep): emit every `*.md` story file under the
# implementation-artifacts tree — the legacy behavior, preserved on demand.
#
# Usage:
#   resolve-sprint-stories.sh --impl-dir <dir> [--sprint-status <path>] [--all]
#
# Stdout: one resolved story-file path per line.
# Exit codes:
#   0 — success (zero paths is NOT an error)
#   1 — usage error / impl-dir missing

set -euo pipefail
LC_ALL=C
export LC_ALL

# Canonical state-tree root.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-}}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPL_DIR=""
SPRINT_STATUS=""
ALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --impl-dir) IMPL_DIR="${2:-}"; shift 2 ;;
    --sprint-status) SPRINT_STATUS="${2:-}"; shift 2 ;;
    --all) ALL=1; shift ;;
    *) printf 'resolve-sprint-stories.sh: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$IMPL_DIR" ] || { printf 'resolve-sprint-stories.sh: --impl-dir is required\n' >&2; exit 1; }
[ -d "$IMPL_DIR" ] || { printf 'resolve-sprint-stories.sh: not a directory: %s\n' "$IMPL_DIR" >&2; exit 1; }

# ---------- --all: full historical sweep (legacy behavior) ----------
if [ "$ALL" -eq 1 ]; then
  find "$IMPL_DIR" -type f -name '*.md' | sort
  exit 0
fi

# ---------- sprint-scoped default ----------
if [ -z "$SPRINT_STATUS" ]; then
  SPRINT_STATUS="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status.yaml"
fi
if [ ! -f "$SPRINT_STATUS" ]; then
  printf 'resolve-sprint-stories.sh: sprint-status not found at %s — pass --all for a full sweep\n' "$SPRINT_STATUS" >&2
  exit 0
fi

# Top-level lifecycle status (NOT a nested block — `status:` is the sprint
# lifecycle value). Read the first top-level `status:` line.
sprint_status_value=$(awk -F: '/^status[[:space:]]*:/ { sub(/^status[[:space:]]*:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit }' "$SPRINT_STATUS")
case "${sprint_status_value:-}" in
  active|review) ;;  # runnable states — proceed
  *)
    printf 'resolve-sprint-stories.sh: active sprint not found (status=%s); pass --all to scan all stories\n' "${sprint_status_value:-unset}" >&2
    exit 0
    ;;
esac

# ---------- Migrate legacy items: key via shared library ----------
# sprint-state.sh runs its own migration at pre-dispatch, but this script is
# invoked independently. Source the shared lib and call migrate under lock.
# If the lib is unavailable (stripped install), the both-keys reader below
# handles the fallback without writing.
_MIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib" 2>/dev/null && pwd 2>/dev/null || echo "")"
if [ -n "$_MIG_LIB_DIR" ] && [ -f "$_MIG_LIB_DIR/acquire-lock.sh" ] && [ -f "$_MIG_LIB_DIR/migrate-items-to-stories.sh" ]; then
  # shellcheck source=../../../scripts/lib/acquire-lock.sh
  . "$_MIG_LIB_DIR/acquire-lock.sh"
  # shellcheck source=../../../scripts/lib/migrate-items-to-stories.sh
  . "$_MIG_LIB_DIR/migrate-items-to-stories.sh"
  migrate_items_to_stories "$SPRINT_STATUS" --lock "${SPRINT_STATUS}.lock" || true
fi

# Committed story keys: union of `stories:` and `items:` blocks.
# When both blocks exist, `stories:` wins on duplicate key, and items-only
# keys are included. Matches the shared reader so the result is identical
# whether migration ran or not.
keys=$(awk '
  /^stories[[:space:]]*:/ { in_stories = 1; in_items = 0; next }
  /^items[[:space:]]*:/ { in_items = 1; in_stories = 0; next }
  (in_stories || in_items) && /^[A-Za-z_]/ { in_stories = 0; in_items = 0 }
  in_stories && /key[[:space:]]*:/ {
    line = $0
    sub(/^[[:space:]]*-?[[:space:]]*key[[:space:]]*:[[:space:]]*/, "", line)
    gsub(/["'"'"'"]/, "", line)
    if (!(line in s_seen)) { s_order[s_n++] = line; s_seen[line] = 1 }
  }
  in_items && /key[[:space:]]*:/ {
    line = $0
    sub(/^[[:space:]]*-?[[:space:]]*key[[:space:]]*:[[:space:]]*/, "", line)
    gsub(/["'"'"'"]/, "", line)
    if (!(line in i_seen)) { i_order[i_n++] = line; i_seen[line] = 1 }
  }
  END {
    for (j = 0; j < s_n; j++) { printf "%s\n", s_order[j]; seen[s_order[j]] = 1 }
    for (j = 0; j < i_n; j++) { if (!(i_order[j] in seen)) printf "%s\n", i_order[j] }
  }
' "$SPRINT_STATUS")

[ -n "$keys" ] || exit 0

# Resolve each key to its file path via the shared resolver.
resolver="$SCRIPT_DIR/../../../scripts/resolve-story-file.sh"
while IFS= read -r key; do
  [ -n "$key" ] || continue
  path=""
  if [ -x "$resolver" ]; then
    path="$("$resolver" "$key" 2>/dev/null || true)"
  fi
  # If the shared resolver did not yield an on-disk file (legacy-path search,
  # different project root, etc.), fall back to a glob against --impl-dir
  # covering both the canonical per-story and legacy flat layouts.
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    path="$(find "$IMPL_DIR" -type f \( -path "*/${key}-*/story.md" -o -name "${key}-*.md" \) 2>/dev/null | head -1)"
  fi
  if [ -n "$path" ] && [ -f "$path" ]; then
    printf '%s\n' "$path"
  fi
done <<<"$keys" | sort -u

exit 0
