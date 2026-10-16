#!/usr/bin/env bash
# tick-story-checkbox.sh — sanctioned writer that ticks a single task or
# subtask checkbox in a story file's "## Tasks / Subtasks" section.
#
# Usage:
#   tick-story-checkbox.sh --file <story.md> --task <N> [--subtask <M>]
#   tick-story-checkbox.sh --file <story.md> --ac <N>
#
# Guarantees:
#   - Only the targeted checkbox line is modified ([ ] -> [x]).
#   - Lines outside the targeted section are never touched.
#   - Already-ticked lines are a no-op (exit 0).
#   - Empty section (no checkboxes at all) is a no-op (exit 0).
#   - Atomic write via temp file + mv (no partial writes).
#   - Concurrent-safe via flock / ln(2) fallback locking.
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

  # Attempt to match and tick the target line (first match only).
  in_section && !in_fenced && !matched {
    if (mode == "task") {
      if (subtask_num == "") {
        # Task line: "- [.] Task N" followed by a non-digit or end-of-field.
        pat = "^- \\[.\\] Task " task_num "([^0-9]|$)"
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
      } else {
        # Subtask line: "  - [.] Subtask N.M" followed by non-digit or end.
        pat = "^  - \\[.\\] Subtask " task_num "\\." subtask_num "([^0-9]|$)"
        if (match($0, pat)) {
          if ($0 ~ /^  - \[x\] / || $0 ~ /^  - \[X\] /) {
            matched = 1
            printf "ALREADY_TICKED" > status_file
            print; next
          }
          if ($0 ~ /^  - \[ \] /) {
            sub(/^  - \[ \] /, "  - [x] ")
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
        printf 'tick-story-checkbox: no matching Subtask %s.%s found in %s\n' \
          "$TASK_NUM" "$SUBTASK_NUM" "$STORY_FILE" >&2
      else
        printf 'tick-story-checkbox: no matching Task %s found in %s\n' \
          "$TASK_NUM" "$STORY_FILE" >&2
      fi
      return 1
      ;;
  esac
}

_tick
