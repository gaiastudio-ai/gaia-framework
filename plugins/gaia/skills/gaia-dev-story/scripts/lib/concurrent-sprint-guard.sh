#!/usr/bin/env bash
# concurrent-sprint-guard.sh — gate new sprint activations against a
# configured limit. Accepts the maximum concurrent active count as $1
# and a newline-delimited list of currently active sprint ids on stdin.
# Exits 0 when the activation is permitted; exits 1 with a warning
# naming the active sprints when the count equals or exceeds the limit.
#
# Empty stdin (zero active sprints) always permits activation.
#
# Usage:
#   echo -e "sprint-84\nsprint-148" | concurrent_sprint_guard 2
#
set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------------------------------------------------------------------------
# concurrent_sprint_guard — public entry point
#
# Args:
#   $1  max_limit  (integer >= 1) — the configured sprint concurrency cap.
#
# Stdin:
#   Newline-delimited list of active sprint ids (may be empty).
#
# Returns:
#   0  when the active count is below the limit (activation permitted).
#   1  when the active count equals or exceeds the limit (refused).
# ---------------------------------------------------------------------------
concurrent_sprint_guard() {
  local max_limit="${1:?usage: concurrent_sprint_guard <max_limit>}"
  local ids="" count=0 line=""

  # Read stdin into a local variable; strip empty lines.
  ids=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    ids="${ids}${ids:+$'\n'}${line}"
    count=$((count + 1))
  done

  if [ "$count" -ge "$max_limit" ]; then
    # Replace newlines with spaces for the warning message.
    local flat=""
    flat="$(printf '%s' "$ids" | tr '\n' ' ')"
    printf 'concurrent-sprint-guard: refused — %d active sprint(s) (limit %d): %s\n' \
      "$count" "$max_limit" "$flat" >&2
    return 1
  fi

  return 0
}

# Source-safe main guard: only run when executed, not when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  concurrent_sprint_guard "$@"
fi
