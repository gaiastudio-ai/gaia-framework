#!/usr/bin/env bash
# dispatch-verb-match.sh — Dispatch-verb taxonomy matcher per ADR-107.
#
# Refs:  ADR-107 (loading contract + SSOT), AF-2026-05-14-6.
# Story: E88-S1.
#
# Provides:
#   - Sourceable function: match_dispatch_verb_in_text "<text>"
#       Exit 0 + matched verbs on stdout if any taxonomy entry matches.
#       Exit 1 otherwise.
#   - Standalone CLI:   dispatch-verb-match.sh "<text>"   (arg form)
#                       echo "<text>" | dispatch-verb-match.sh   (stdin form)
#
# Implementation discipline:
#   - Loads the taxonomy via load-taxonomy.sh --as-grep-file (SSOT).
#   - Matches with `grep -wFf <file>` (fixed-string, word-boundary).
#   - Inline `rm -f` cleanup of the tempfile after each call. (Alternative:
#     trap-based EXIT cleanup. Inline chosen for bounded-lifetime call sites.)

set -euo pipefail
LC_ALL=C
export LC_ALL

# Resolve this script's directory so the function works both when sourced
# (BASH_SOURCE[0] points at this file) and when invoked standalone.
_DISPATCH_VERB_MATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# match_dispatch_verb_in_text <text>
#
# Returns 0 and emits matched verb lines on stdout if `text` contains any
# dispatch verb. Returns 1 (no match) with empty stdout otherwise.
match_dispatch_verb_in_text() {
  local text="${1-}"
  [[ -z "$text" ]] && return 1

  local grep_file
  grep_file="$("$_DISPATCH_VERB_MATCH_DIR/load-taxonomy.sh" --taxonomy dispatch --as-grep-file)"

  local result=""
  result="$(printf '%s' "$text" | grep -wFof "$grep_file" || true)"
  rm -f "$grep_file"

  if [[ -n "$result" ]]; then
    # Deduplicate matched entries while preserving order.
    printf '%s\n' "$result" | awk '!seen[$0]++'
    return 0
  fi
  return 1
}

# Standalone CLI dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -gt 0 ]]; then
    match_dispatch_verb_in_text "$*"
  else
    text="$(cat)"
    match_dispatch_verb_in_text "$text"
  fi
fi
