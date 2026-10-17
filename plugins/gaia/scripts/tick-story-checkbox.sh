#!/usr/bin/env bash
# tick-story-checkbox.sh — sanctioned writer that ticks a single task or
# subtask checkbox in a story file's "## Tasks / Subtasks" section.
#
# Usage:
#   tick-story-checkbox.sh --file <story.md> --task <N> [--subtask <M>]
#   tick-story-checkbox.sh --file <story.md> --ac <N>
#
# Supported task formats (all matched case-insensitively for the label word):
#   - [ ] Task N -- ...         (plain)
#   - [ ] Task N: ...           (plain with colon)
#   - [ ] **Task N:** ...       (bold)
#   - [ ] **Task N: ...**       (bold wrapping)
#   - [ ] **TN** -- ...         (shorthand bold)
#   - [ ] **TN:** ...           (shorthand bold with colon)
#   - [ ] T1 -- ...             (shorthand plain)
#   - [ ] T1 (AC: 1, 2)        (shorthand with parens)
#
# Supported subtask formats:
#   - [ ] Subtask N.M: ...      (explicit "Subtask" label)
#   - [ ] N.M: ...              (bare number)
#   - [ ] N.M ...               (bare number, no colon)
#   - [ ] **N.M:** ...          (bold bare number)
#
# Guarantees:
#   - Only the targeted checkbox line is modified ([ ] -> [x]).
#   - Lines outside the targeted section are never touched.
#   - Already-ticked lines are a no-op (exit 0).
#   - Empty section (no checkboxes at all) is a no-op (exit 0).
#   - Atomic write via temp file + mv (no partial writes).
#   - Concurrent-safe via flock / ln(2) fallback locking.
#   - Symlinked paths are resolved before writing.
#   - Bash 3.2 compatible (no associative arrays, no mapfile).
#
# Exit codes:
#   0  success (ticked, already ticked, or section empty)
#   1  usage error, missing file, or section has checkboxes but none matched

set -euo pipefail
LC_ALL=C; export LC_ALL

# --- Resolve plugin root for the lock helper ---

_resolve_plugin_root() {
  local me
  me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # scripts/ is directly under the plugin root
  printf '%s' "$(cd "$me/.." && pwd)"
}

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(_resolve_plugin_root)}"
LOCK_LIB="${PLUGIN_ROOT}/scripts/lib/acquire-lock.sh"

# --- Argument parsing ---

STORY_FILE=""
TASK_NUM=""
SUBTASK_NUM=""
AC_NUM=""

_usage() {
  printf 'Usage: %s --file <story.md> --task <N> [--subtask <M>]\n' "$(basename "$0")" >&2
  printf '       %s --file <story.md> --ac <N>\n' "$(basename "$0")" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file)    shift; STORY_FILE="${1:-}"; shift ;;
    --task)    shift; TASK_NUM="${1:-}"; shift ;;
    --subtask) shift; SUBTASK_NUM="${1:-}"; shift ;;
    --ac)      shift; AC_NUM="${1:-}"; shift ;;
    --help|-h) _usage ;;
    *) printf 'tick-story-checkbox: unknown argument: %s\n' "$1" >&2; _usage ;;
  esac
done

if [ -z "$STORY_FILE" ]; then
  printf 'tick-story-checkbox: --file is required\n' >&2
  exit 1
fi

if [ ! -f "$STORY_FILE" ]; then
  printf 'tick-story-checkbox: file not found: %s\n' "$STORY_FILE" >&2
  exit 1
fi

# Resolve symlinks so mv writes through to the real file.
if [ -L "$STORY_FILE" ]; then
  _resolved="$(perl -MCwd -e 'print Cwd::realpath($ARGV[0])' "$STORY_FILE" 2>/dev/null)" || \
  _resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$STORY_FILE" 2>/dev/null)" || \
  _resolved="$(readlink -f "$STORY_FILE" 2>/dev/null)" || \
  _resolved=""
  if [ -n "$_resolved" ] && [ -f "$_resolved" ]; then
    STORY_FILE="$_resolved"
  fi
fi

# Exactly one of (--task [--subtask]) or (--ac) must be given.
if [ -n "$AC_NUM" ] && [ -n "$TASK_NUM" ]; then
  printf 'tick-story-checkbox: --ac and --task are mutually exclusive\n' >&2
  exit 1
fi
if [ -z "$AC_NUM" ] && [ -z "$TASK_NUM" ]; then
  printf 'tick-story-checkbox: --task or --ac is required\n' >&2
  exit 1
fi

# Validate numeric arguments.
_is_positive_int() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

if [ -n "$TASK_NUM" ] && ! _is_positive_int "$TASK_NUM"; then
  printf 'tick-story-checkbox: --task must be a positive integer, got: %s\n' "$TASK_NUM" >&2
  exit 1
fi
if [ -n "$SUBTASK_NUM" ] && ! _is_positive_int "$SUBTASK_NUM"; then
  printf 'tick-story-checkbox: --subtask must be a positive integer, got: %s\n' "$SUBTASK_NUM" >&2
  exit 1
fi
if [ -n "$AC_NUM" ] && ! _is_positive_int "$AC_NUM"; then
  printf 'tick-story-checkbox: --ac must be a positive integer, got: %s\n' "$AC_NUM" >&2
  exit 1
fi

# --- Locking ---
# Source the lock helper if available; if not, degrade to no locking
# (single-writer use cases remain safe via temp+mv atomicity).

_LOCK_FD=200
_LOCK_ACQUIRED=0

_acquire() {
  if [ ! -f "$LOCK_LIB" ]; then
    return 0
  fi
  # shellcheck source=lib/acquire-lock.sh
  . "$LOCK_LIB"
  local lock_path="${STORY_FILE}.lock"
  if acquire_lock "$lock_path" 10 "$_LOCK_FD"; then
    _LOCK_ACQUIRED=1
  else
    printf 'tick-story-checkbox: warning: could not acquire lock on %s (proceeding anyway)\n' \
      "$lock_path" >&2
  fi
}

_release() {
  if [ "$_LOCK_ACQUIRED" = "1" ]; then
    release_lock "$_LOCK_FD"
    _LOCK_ACQUIRED=0
  fi
}

trap '_release' EXIT

# --- Core: locate and tick the target line ---
#
# A single awk pass reads the story file, tracks the current section by
# detecting ## headings (case-insensitive), skips fenced code blocks, and
# changes the first matching `- [ ]` to `- [x]`. The result is written to
# a status file: MATCHED | ALREADY_TICKED | NO_MATCH | EMPTY_SECTION.
#
# Task matching handles these formats (N = task_num):
#   "Task N"   — plain or bold, followed by non-digit
#   "TN"       — shorthand, followed by non-digit (bold or plain)
# Subtask matching handles (N.M = task_num.subtask_num):
#   "Subtask N.M" — explicit label, followed by non-digit
#   "N.M"         — bare number, followed by non-digit
# Bold markers (**) and leading whitespace on subtask lines are tolerated.

_tick() {
  local section_header=""
  local mode=""

  if [ -n "$AC_NUM" ]; then
    section_header="acceptance criteria"
    mode="ac"
  else
    section_header="tasks / subtasks"
    mode="task"
  fi

  _acquire

  local tmp_file="${STORY_FILE}.tick-tmp.$$.$RANDOM"
  local status_file="${STORY_FILE}.tick-status.$$.$RANDOM"

  awk \
    -v section_hdr="$section_header" \
    -v mode="$mode" \
    -v task_num="$TASK_NUM" \
    -v subtask_num="$SUBTASK_NUM" \
    -v ac_num="$AC_NUM" \
    -v status_file="$status_file" \
  '
  BEGIN {
    in_section = 0
    matched = 0
    in_fenced = 0
    has_checkboxes = 0
  }

  # Track fenced code blocks — never tick inside them.
  /^```/ {
    in_fenced = !in_fenced
    print
    next
  }

  # Section tracking via ## headings (case-insensitive).
  /^## / {
    lower = tolower($0)
    gsub(/[[:space:]]+$/, "", lower)
    if (lower == "## " section_hdr) {
      in_section = 1
    } else {
      in_section = 0
    }
    print
    next
  }

  # Count checkboxes in the target section (for empty-section detection).
  in_section && !in_fenced && /^[[:space:]]*- \[/ {
    has_checkboxes = 1
  }

  # --- Helper: test whether a task line matches task_num ---
  # Extracts the content after "- [.] " and checks for:
  #   (optional **) Task N (non-digit or end)
  #   (optional **) TN (non-digit or end)
  # Returns 1 in _task_hit if matched.
  function is_task_match(line,    content, pat_task, pat_t) {
    # Strip leading "- [.] " and optional bold marker.
    content = line
    sub(/^- \[.\] /, "", content)
    sub(/^\*\*/, "", content)
    # "Task N" followed by non-digit or end.
    pat_task = "^[Tt]ask[[:space:]]+" task_num "([^0-9]|$)"
    if (match(content, pat_task)) return 1
    # "TN" followed by non-digit or end (T is uppercase always in shorthand).
    pat_t = "^T" task_num "([^0-9]|$)"
    if (match(content, pat_t)) return 1
    return 0
  }

  # --- Helper: test whether a subtask line matches task_num.subtask_num ---
  # Extracts the content after "  - [.] " and checks for:
  #   (optional **) (optional "Subtask ") N.M (non-digit or end)
  function is_subtask_match(line,    content, pat_sub, pat_bare) {
    # Strip leading whitespace + "- [.] " and optional bold marker.
    content = line
    sub(/^[[:space:]]*- \[.\] /, "", content)
    sub(/^\*\*/, "", content)
    # "Subtask N.M" followed by non-digit or end.
    pat_sub = "^[Ss]ubtask[[:space:]]+" task_num "\\." subtask_num "([^0-9]|$)"
    if (match(content, pat_sub)) return 1
    # Bare "N.M" followed by non-digit or end.
    pat_bare = "^" task_num "\\." subtask_num "([^0-9]|$)"
    if (match(content, pat_bare)) return 1
    return 0
  }

  # Attempt to match and tick the target line (first match only).
  in_section && !in_fenced && !matched {
    if (mode == "task") {
      if (subtask_num == "") {
        # Top-level task line (not indented).
        if (/^- \[.\] / && is_task_match($0)) {
          if ($0 ~ /^- \[x\] / || $0 ~ /^- \[X\] /) {
            matched = 1
            printf "ALREADY_TICKED" > status_file
            print; next
          }
          if ($0 ~ /^- \[ \] /) {
            sub(/^- \[ \] /, "- [x] ")
            matched = 1
            printf "MATCHED" > status_file
            print; next
          }
        }
      } else {
        # Subtask line (indented).
        if (/^[[:space:]]+- \[.\] / && is_subtask_match($0)) {
          if ($0 ~ /^[[:space:]]+- \[x\] / || $0 ~ /^[[:space:]]+- \[X\] /) {
            matched = 1
            printf "ALREADY_TICKED" > status_file
            print; next
          }
          if ($0 ~ /^[[:space:]]+- \[ \] /) {
            # Replace only the checkbox, preserving all leading whitespace.
            sub(/- \[ \] /, "- [x] ")
            matched = 1
            printf "MATCHED" > status_file
            print; next
          }
        }
      }
    } else if (mode == "ac") {
      # AC line: "- [.] **ACN:**" or "- [.] ACN:" (bold optional).
      pat = "^- \\[.\\] (\\*\\*)?AC" ac_num ":"
      if (match($0, pat)) {
        if ($0 ~ /^- \[x\] / || $0 ~ /^- \[X\] /) {
          matched = 1
          printf "ALREADY_TICKED" > status_file
          print; next
        }
        if ($0 ~ /^- \[ \] /) {
          sub(/^- \[ \] /, "- [x] ")
          matched = 1
          printf "MATCHED" > status_file
          print; next
        }
      }
    }
  }

  { print }

  END {
    if (!matched) {
      if (has_checkboxes)
        printf "NO_MATCH" > status_file
      else
        printf "EMPTY_SECTION" > status_file
    }
  }
  ' "$STORY_FILE" > "$tmp_file"

  local result=""
  if [ -f "$status_file" ]; then
    result="$(cat "$status_file")"
    rm -f "$status_file"
  fi

  case "$result" in
    MATCHED)
      mv -f "$tmp_file" "$STORY_FILE"
      return 0
      ;;
    ALREADY_TICKED)
      rm -f "$tmp_file"
      return 0
      ;;
    EMPTY_SECTION)
      # Section has no checkboxes at all — graceful no-op per contract.
      rm -f "$tmp_file"
      return 0
      ;;
    NO_MATCH|"")
      rm -f "$tmp_file"
      if [ -n "$AC_NUM" ]; then
        printf 'tick-story-checkbox: no matching AC %s found in %s\n' \
          "$AC_NUM" "$STORY_FILE" >&2
      elif [ -n "$SUBTASK_NUM" ]; then
        printf 'tick-story-checkbox: no matching subtask %s.%s found in %s\n' \
          "$TASK_NUM" "$SUBTASK_NUM" "$STORY_FILE" >&2
      else
        printf 'tick-story-checkbox: no matching task %s found in %s\n' \
          "$TASK_NUM" "$STORY_FILE" >&2
      fi
      return 1
      ;;
  esac
}

_tick
