#!/usr/bin/env bash
# resolve-sprint-stories.sh — emit the set of story files /gaia-triage-findings
# should scan.
#
# DEFAULT (sprint-scoped): discover all runnable sprints from per-sprint state
# files (sprint-status-{id}.yaml) and the main sprint-status.yaml (when its
# sprint has no per-sprint counterpart), then emit the file paths of their
# committed stories. This is the token-budget / performance fix — historical
# stories from prior sprints have already been triaged and re-scanning them
# wastes context.
#
#   - Per-sprint files and the main file are both read; keys are unioned and
#     deduplicated across sprints.
#   - The committed stories are read from the TOP-LEVEL `stories:` sequence
#     (each entry has a `key:`).
#   - Gating: each sprint must be in a runnable lifecycle state (`active` or
#     `review`). Closed/planned sprints are skipped. When no runnable sprint
#     is found, nothing is emitted with an informational stderr message.
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
# Discover sprint-status files: explicit path, per-sprint files, or main file.
_SPRINT_STATUS_FILES=()
if [ -n "$SPRINT_STATUS" ]; then
  # Explicit --sprint-status: use only that file.
  if [ ! -f "$SPRINT_STATUS" ]; then
    printf 'resolve-sprint-stories.sh: sprint-status not found at %s — pass --all for a full sweep\n' "$SPRINT_STATUS" >&2
    exit 0
  fi
  _SPRINT_STATUS_FILES=("$SPRINT_STATUS")
else
  # Discover per-sprint state files AND the main file for concurrent-sprint
  # support. The main file is included when its sprint has no per-sprint file
  # (same union rule as sprint-progress-snapshot.sh).
  _state_dir="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state"
  _main_file="${_state_dir}/sprint-status.yaml"
  _has_per_sprint=0
  if [ -d "$_state_dir" ]; then
    for _psf in "$_state_dir"/sprint-status-*.yaml; do
      [ -f "$_psf" ] || continue
      # Skip lock/result files.
      case "$_psf" in *.lock|*.result) continue ;; esac
      _SPRINT_STATUS_FILES+=("$_psf")
      _has_per_sprint=1
    done
  fi
  # Always include the main file when it exists and its sprint has no
  # per-sprint counterpart (prevents a stale closed per-sprint file from
  # hiding an active main-file sprint).
  if [ -f "$_main_file" ]; then
    if [ "$_has_per_sprint" -eq 0 ]; then
      _SPRINT_STATUS_FILES=("$_main_file")
    else
      # Check if the main file's sprint already has a per-sprint file.
      # Trim inline comments, trailing whitespace and CR (same as the status awk).
      _main_sid=""
      _main_sid=$(awk '/^sprint_id[[:space:]]*:/ { sub(/^sprint_id[[:space:]]*:[[:space:]]*/, ""); gsub(/["'"'"'"]/, ""); sub(/[[:space:]]*#.*$/, ""); sub(/[[:space:]]*$/, ""); gsub(/\r/, ""); print; exit }' "$_main_file" 2>/dev/null) || _main_sid=""
      if [ -n "$_main_sid" ] && [ ! -f "${_state_dir}/sprint-status-${_main_sid}.yaml" ]; then
        _SPRINT_STATUS_FILES+=("$_main_file")
      fi
    fi
  elif [ "${#_SPRINT_STATUS_FILES[@]}" -eq 0 ]; then
    printf 'resolve-sprint-stories.sh: sprint-status not found at %s — pass --all for a full sweep\n' "$_main_file" >&2
    exit 0
  fi
fi

# ---------- Migrate legacy items: key via shared library ----------
# sprint-state.sh runs its own migration at pre-dispatch, but this script is
# invoked independently. Source the shared lib and call migrate under lock.
# If the lib is unavailable (stripped install), the both-keys reader below
# handles the fallback without writing.
_MIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib" 2>/dev/null && pwd 2>/dev/null || echo "")"
_mig_loaded=0
if [ -n "$_MIG_LIB_DIR" ] && [ -f "$_MIG_LIB_DIR/acquire-lock.sh" ] && [ -f "$_MIG_LIB_DIR/migrate-items-to-stories.sh" ]; then
  # shellcheck source=../../../scripts/lib/acquire-lock.sh
  . "$_MIG_LIB_DIR/acquire-lock.sh"
  # shellcheck source=../../../scripts/lib/migrate-items-to-stories.sh
  . "$_MIG_LIB_DIR/migrate-items-to-stories.sh"
  _mig_loaded=1
fi

# Iterate over discovered sprint-status files, collecting story keys from
# each runnable sprint (active or review). This supports concurrent sprints
# where each has its own per-sprint state file.
keys=""
_any_runnable=0
for _ssf in "${_SPRINT_STATUS_FILES[@]}"; do
  [ -f "$_ssf" ] || continue

  # Top-level lifecycle status (trimmed: inline comments, trailing whitespace, CR).
  _ssf_status=$(awk '/^status[[:space:]]*:/ { sub(/^status[[:space:]]*:[[:space:]]*/, ""); gsub(/["'"'"'"]/, ""); sub(/[[:space:]]*#.*$/, ""); sub(/[[:space:]]*$/, ""); gsub(/\r/, ""); print; exit }' "$_ssf")
  case "${_ssf_status:-}" in
    active|review) _any_runnable=1 ;;
    *) continue ;;  # skip non-runnable sprints
  esac

  # Migrate items if the lib is available.
  if [ "$_mig_loaded" -eq 1 ]; then
    migrate_items_to_stories "$_ssf" --lock "${_ssf}.lock" || true
  fi

  # Committed story keys: union of stories: and items: blocks.
  _file_keys=$(awk '
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
  ' "$_ssf")
  if [ -n "$_file_keys" ]; then
    keys="${keys:+${keys}
}${_file_keys}"
  fi
done

if [ "$_any_runnable" -eq 0 ]; then
  printf 'resolve-sprint-stories.sh: runnable sprint not found; pass --all to scan all stories\n' >&2
  exit 0
fi

# Deduplicate keys across sprints.
if [ -n "$keys" ]; then
  keys="$(printf '%s\n' "$keys" | awk '!seen[$0]++')"
fi

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
