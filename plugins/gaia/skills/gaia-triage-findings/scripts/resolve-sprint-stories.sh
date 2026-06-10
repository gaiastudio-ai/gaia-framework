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
#   - Gating: only when the top-level `status:` is `active` do we sprint-scope;
#     a `closed`/`planned` sprint emits nothing with an informational message
#     on stderr (the caller decides whether to fall back to --all).
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
  SPRINT_STATUS=".gaia/state/sprint-status.yaml"
fi
if [ ! -f "$SPRINT_STATUS" ]; then
  printf 'resolve-sprint-stories.sh: sprint-status not found at %s — pass --all for a full sweep\n' "$SPRINT_STATUS" >&2
  exit 0
fi

# Top-level lifecycle status (NOT a nested block — `status:` is the sprint
# lifecycle value). Read the first top-level `status:` line.
sprint_status_value=$(awk -F: '/^status[[:space:]]*:/ { sub(/^status[[:space:]]*:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit }' "$SPRINT_STATUS")
if [ "$sprint_status_value" != "active" ]; then
  printf 'resolve-sprint-stories.sh: active sprint not found (status=%s); pass --all to scan all stories\n' "${sprint_status_value:-unset}" >&2
  exit 0
fi

# Committed story keys from the top-level `stories:` sequence (`- key: "…"`).
keys=$(awk '
  /^stories[[:space:]]*:/ { in_stories = 1; next }
  in_stories && /^[A-Za-z_]/ { in_stories = 0 }   # next top-level key ends the block
  in_stories && /key[[:space:]]*:/ {
    line = $0
    sub(/^[[:space:]]*-?[[:space:]]*key[[:space:]]*:[[:space:]]*/, "", line)
    gsub(/["'\'']/, "", line)
    print line
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
