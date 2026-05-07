#!/usr/bin/env bash
# check-status-discipline.sh — pre-commit guard for status-edit discipline (E59-S5).
#
# Purpose
# -------
# Enforce the framework-wide hard rule that story status changes go through
# `transition-story-status.sh`. Direct edits to `status:` fields in any of the
# four canonical surfaces are FORBIDDEN. This script scans the staged diff for
# such edits and blocks the commit when an edit is not accompanied by evidence
# that the transition script ran.
#
# Surfaces guarded
# ----------------
#   1. Story frontmatter `status:` line in either layout (E79-S4):
#      - canonical: `docs/implementation-artifacts/epic-*/stories/E*-S*-*.md`
#      - legacy flat: `docs/implementation-artifacts/E*-S*-*.md`
#   2. `docs/implementation-artifacts/sprint-status.yaml` per-story `status:` keys
#   3. `docs/planning-artifacts/epics-and-stories.md` per-story `**Status:** ...`
#      indicators
#
# Legitimate-transition heuristic
# -------------------------------
# The script considers an edit legitimate when a fresh marker file written by
# `transition-story-status.sh` is present at:
#
#   $STATUS_TRANSITION_MARKER  (default: <git-root>/.git/gaia-status-transition.marker)
#
# Marker format (key=value lines):
#   story_key=<E*-S*>
#   timestamp=<unix-epoch-seconds>
#   from=<state>
#   to=<state>
#
# Freshness window: ${MARKER_TTL_SECONDS:-300} seconds. Markers older than the
# window are ignored. The marker is single-shot — it covers any number of
# `status:` edits in the same change-set, but only for the recorded `story_key`.
#
# Sprint-boundary exception
# -------------------------
# Per memory `feedback_sprint_boundary_yaml_write.md`, sprint-boundary writes
# to `sprint-status.yaml` (new sprint block seeding) are allowed without a
# transition marker because `transition-story-status.sh` rejects self-transitions
# and cannot seed new sprints. Heuristic: sprint-status.yaml is a brand-new file
# in the staged diff (no previous index entry) → boundary path.
#
# Exit-code contract
# ------------------
#   0  no violations OR all status edits accompanied by marker / boundary path
#   1  at least one violation; stderr names <file>:<line> for each
#
# Usage
# -----
#   check-status-discipline.sh                                # default
#   check-status-discipline.sh --staged-files <file>          # synthetic list
#   check-status-discipline.sh --help
#
# Refs: ADR-074 contract C3, AF-2026-04-28-7, ADR-042 (scripts-over-LLM),
# ADR-067 (YOLO contract — pre-commit gate is outside YOLO scope).
# Story: E59-S5.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="check-status-discipline.sh"
MARKER_TTL_SECONDS="${MARKER_TTL_SECONDS:-300}"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

usage() {
  cat <<'USAGE'
Usage:
  check-status-discipline.sh [--staged-files <path-to-list>]
  check-status-discipline.sh --help

Scans the staged git diff for direct status: edits in story frontmatter,
sprint-status.yaml, or epics-and-stories.md. Blocks the commit unless a
fresh transition marker is present at .git/gaia-status-transition.marker
(or a documented sprint-boundary exception applies).

Exit codes:
  0 no violations
  1 violation(s) detected; stderr lists <file>:<line>
USAGE
}

# ---------- Argument parsing ----------
STAGED_FILES_LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --staged-files) STAGED_FILES_LIST="${2:-}"; shift 2 ;;
    --help|-h)      usage; exit 0 ;;
    *) err "unknown option: $1"; usage >&2; exit 2 ;;
  esac
done

# ---------- Resolve git-root for marker location ----------
# PROJECT_PATH wins (test harness sets it); fall back to git rev-parse from CWD.
if [ -n "${PROJECT_PATH:-}" ] && [ -d "${PROJECT_PATH}/.git" ]; then
  git_root="$PROJECT_PATH"
elif git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  : # ok
else
  git_root="${PROJECT_PATH:-$PWD}"
fi
: "${STATUS_TRANSITION_MARKER:=${git_root}/.git/gaia-status-transition.marker}"

# ---------- Read staged file list ----------
if [ -n "$STAGED_FILES_LIST" ]; then
  if [ ! -r "$STAGED_FILES_LIST" ]; then
    err "--staged-files path not readable: $STAGED_FILES_LIST"
    exit 2
  fi
  staged_files=$(cat "$STAGED_FILES_LIST")
else
  staged_files=$(cd "$git_root" && git diff --cached --name-only 2>/dev/null || true)
fi

# Quick exit: no staged files → silent pass
if [ -z "$staged_files" ]; then
  exit 0
fi

# ---------- Read staged diff ----------
# Tests can override via STAGED_DIFF_FILE (a pre-built diff payload); production
# resolves via `git diff --cached`.
if [ -n "${STAGED_DIFF_FILE:-}" ]; then
  if [ ! -r "$STAGED_DIFF_FILE" ]; then
    err "STAGED_DIFF_FILE not readable: $STAGED_DIFF_FILE"
    exit 2
  fi
  staged_diff=$(cat "$STAGED_DIFF_FILE")
else
  staged_diff=$(cd "$git_root" && git diff --cached -U0 2>/dev/null || true)
fi

# ---------- Marker freshness check ----------
# Returns the story_key that the marker covers, or empty string.
marker_story_key() {
  if [ ! -r "$STATUS_TRANSITION_MARKER" ]; then
    return 0
  fi
  local key ts now age
  key=$(awk -F= '$1=="story_key"{print $2; exit}' "$STATUS_TRANSITION_MARKER")
  ts=$(awk -F= '$1=="timestamp"{print $2; exit}' "$STATUS_TRANSITION_MARKER")
  if [ -z "$key" ] || [ -z "$ts" ]; then
    return 0
  fi
  now=$(date -u +%s)
  age=$(( now - ts ))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$MARKER_TTL_SECONDS" ]; then
    return 0  # stale → ignore
  fi
  printf '%s' "$key"
}

MARKER_KEY=$(marker_story_key || true)

# ---------- Helpers ----------

# Classify a path. Echoes one of: story_frontmatter, sprint_status, epics_md, other
classify_path() {
  local p="$1"
  case "$p" in
    # Canonical nested layout (E79-S4) — epic-*/stories/{key}-*.md
    docs/implementation-artifacts/epic-*/stories/E*-S*-*.md) printf 'story_frontmatter' ;;
    # Legacy flat layout — read-only fallback until E79-S6 migration completes.
    docs/implementation-artifacts/E*-S*-*.md) printf 'story_frontmatter' ;;
    docs/implementation-artifacts/sprint-status.yaml) printf 'sprint_status' ;;
    docs/planning-artifacts/epics-and-stories.md) printf 'epics_md' ;;
    *) printf 'other' ;;
  esac
}

# Extract story key (e.g. "E1-S2") from a story-frontmatter file path.
story_key_from_path() {
  local p="$1"
  printf '%s' "$p" | sed -n 's|.*/\(E[0-9][0-9]*-S[0-9][0-9]*\)-.*|\1|p'
}

# Is the staged diff for sprint-status.yaml an addition of a brand new file
# (sprint-boundary seed)? Heuristic: staged diff shows /dev/null as the source.
is_sprint_boundary_diff() {
  local file="$1"
  printf '%s\n' "$staged_diff" | awk -v f="$file" '
    BEGIN { in_block=0; new_file=0 }
    $0 ~ "^diff --git " { in_block=0; if ($0 ~ "b/" f "$") in_block=1; next }
    in_block && $0 ~ "^new file mode " { new_file=1 }
    in_block && /^--- \/dev\/null/ { new_file=1 }
    END { exit (new_file ? 0 : 1) }
  '
}

# Walk the staged diff and emit, for each violating line in target surfaces,
# a record of the form "<file>:<line>".  We use the post-image hunk header
# (e.g. "@@ -2,1 +2,1 @@") to compute line numbers for added/changed lines.
detect_violations() {
  local diff_text="$1"
  printf '%s\n' "$diff_text" | awk '
    function emit(file, lineno, text) {
      printf "%s:%d:%s\n", file, lineno, text
    }
    /^diff --git / {
      cur_file = ""
      # b/<path> token
      n = split($0, parts, " ")
      if (n >= 4) {
        b = parts[4]
        sub(/^b\//, "", b)
        cur_file = b
      }
      next
    }
    /^@@ / {
      # parse "+<start>,<count>" segment
      hunk = $0
      if (match(hunk, /\+[0-9]+(,[0-9]+)?/)) {
        seg = substr(hunk, RSTART, RLENGTH)
        sub(/^\+/, "", seg)
        n2 = split(seg, sp, ",")
        new_start = sp[1] + 0
        new_count = (n2 >= 2 ? sp[2] + 0 : 1)
      }
      cur_lineno = new_start
      next
    }
    # Skip context / removed lines for line-number tracking — only added/kept
    # lines advance the post-image lineno. We only flag added (+) lines.
    /^-/ { next }
    /^\+/ {
      # Strip leading +
      content = substr($0, 2)
      # Skip the +++ header line (path designator)
      if (content ~ /^\+\+/) next
      # Surface 1: story frontmatter status: (canonical nested OR legacy flat path; E79-S4)
      if (cur_file ~ /docs\/implementation-artifacts\/(epic-[^\/]+\/stories\/)?E[0-9]+-S[0-9]+-.+\.md$/ && content ~ /^status:[[:space:]]*/) {
        emit(cur_file, cur_lineno, content)
      }
      # Surface 2: sprint-status.yaml per-story status:
      else if (cur_file ~ /docs\/implementation-artifacts\/sprint-status\.yaml$/ && content ~ /^[[:space:]]+status:[[:space:]]*/) {
        emit(cur_file, cur_lineno, content)
      }
      # Surface 3: epics-and-stories.md **Status:** indicator
      else if (cur_file ~ /docs\/planning-artifacts\/epics-and-stories\.md$/ && content ~ /\*\*Status:\*\*/) {
        emit(cur_file, cur_lineno, content)
      }
      cur_lineno++
      next
    }
    /^ / {
      cur_lineno++
      next
    }
  '
}

# ---------- Detect violations ----------
violations=$(detect_violations "$staged_diff" || true)

if [ -z "$violations" ]; then
  exit 0
fi

# ---------- Apply legitimate-transition + boundary exceptions ----------
# A violation is *cleared* if either:
#   (a) marker present and covers the same story_key for story-frontmatter edits, OR
#   (b) the file is sprint-status.yaml AND the diff shows a brand-new file (boundary)
remaining=""
while IFS= read -r record; do
  [ -n "$record" ] || continue
  rec_file=${record%%:*}
  rest=${record#*:}
  rec_line=${rest%%:*}
  cls=$(classify_path "$rec_file")

  # Boundary exception for sprint-status.yaml
  if [ "$cls" = "sprint_status" ] && is_sprint_boundary_diff "$rec_file"; then
    continue
  fi

  # Marker exception for story_frontmatter
  if [ "$cls" = "story_frontmatter" ] && [ -n "$MARKER_KEY" ]; then
    skey=$(story_key_from_path "$rec_file")
    if [ "$skey" = "$MARKER_KEY" ]; then
      continue
    fi
  fi

  # Marker exception for sprint_status / epics_md (the marker covers the
  # same change-set, regardless of which surface was touched alongside)
  if { [ "$cls" = "sprint_status" ] || [ "$cls" = "epics_md" ]; } && [ -n "$MARKER_KEY" ]; then
    continue
  fi

  remaining="${remaining}${record}"$'\n'
done <<<"$violations"

if [ -z "${remaining%$'\n'}" ]; then
  exit 0
fi

# ---------- Report and fail ----------
err "ERROR: direct status: edit detected without transition-story-status.sh invocation:"
while IFS= read -r record; do
  [ -n "$record" ] || continue
  rec_file=${record%%:*}
  rest=${record#*:}
  rec_line=${rest%%:*}
  err "  $rec_file:$rec_line"
done <<<"$remaining"
err "Use: scripts/transition-story-status.sh <KEY> --to <STATUS>"
exit 1
