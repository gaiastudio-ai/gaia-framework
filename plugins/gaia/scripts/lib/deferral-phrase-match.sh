#!/usr/bin/env bash
# deferral-phrase-match.sh — Deferral-phrase taxonomy matcher per ADR-107.
#
# Refs:  ADR-107 (loading contract + SSOT), AF-2026-05-14-6.
# Story: E88-S1.
#
# Provides:
#   - Sourceable function: match_deferral_phrase_in_text "<text>"
#       Exit 0 + matched phrases on stdout if any taxonomy entry matches.
#       Exit 1 otherwise.
#   - Standalone CLI:   deferral-phrase-match.sh "<text>"   (arg form)
#                       echo "<text>" | deferral-phrase-match.sh   (stdin form)
#
# Implementation discipline:
#   - Loads the taxonomy via load-taxonomy.sh --as-grep-file (SSOT).
#   - Matches with `grep -wFf <file>` (fixed-string, word-boundary). The
#     `-w` flag is whole-word semantics — for multi-word phrases like
#     "production wiring", grep -wF matches the entire phrase with word
#     boundaries on both sides.
#   - Inline `rm -f` cleanup of the tempfile after each call.

set -euo pipefail
LC_ALL=C
export LC_ALL

_DEFERRAL_PHRASE_MATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# match_deferral_phrase_in_text <text>
#
# Returns 0 and emits matched phrase lines on stdout if `text` contains any
# deferral phrase. Returns 1 (no match) with empty stdout otherwise.
match_deferral_phrase_in_text() {
  local text="${1-}"
  [[ -z "$text" ]] && return 1

  local grep_file
  grep_file="$("$_DEFERRAL_PHRASE_MATCH_DIR/load-taxonomy.sh" --taxonomy deferral --as-grep-file)"

  local result=""
  result="$(printf '%s' "$text" | grep -wFof "$grep_file" || true)"
  rm -f "$grep_file"

  if [[ -n "$result" ]]; then
    printf '%s\n' "$result" | awk '!seen[$0]++'
    return 0
  fi
  return 1
}

# Standalone CLI dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -gt 0 ]]; then
    match_deferral_phrase_in_text "$*"
  else
    text="$(cat)"
    match_deferral_phrase_in_text "$text"
  fi
fi
