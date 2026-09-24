#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# verdict-provenance-check.sh — deterministic verdict-provenance guard.
#
# Rejects a candidate verdict/notes text if any substring above a trivial
# length threshold appears verbatim inside the boundary-marker-wrapped
# project content.  Called by the design-review skill before every
# add-review invocation.
#
# Usage: verdict-provenance-check.sh <candidate-notes> <boundary-content>
#   - candidate-notes:  the text of the proposed verdict/notes
#   - boundary-content: the full boundary-marker-wrapped project content
#
# Exit codes:
#   0  — notes text passes the provenance check (no verbatim match)
#   1  — notes text contains a verbatim match from the boundary content
#   2  — argument error (missing or empty arguments)

_die() { printf 'verdict-provenance-check.sh: %s\n' "$1" >&2; exit 2; }

# Minimum substring length to trigger a match.  Short common words
# ("the", "and", "with") always appear in both texts; only matches
# at or above this threshold count as verbatim transcription.
MIN_MATCH_LENGTH=20

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

[ $# -ge 2 ] || _die "usage: verdict-provenance-check.sh <candidate-notes> <boundary-content>"
[ -n "$1" ]   || _die "candidate-notes must not be empty"
[ -n "$2" ]   || _die "boundary-content must not be empty"

candidate="$1"
boundary="$2"

# ---------------------------------------------------------------------------
# Extract content between boundary markers (strip the markers themselves)
# ---------------------------------------------------------------------------

_extract_inner() {
  local text="$1"
  # Remove everything before the first opening marker (inclusive)
  local after_open="${text#*<<<DESIGN_PROJECT_BOUNDARY>>>}"
  # If no marker found, use the full text
  if [ "$after_open" = "$text" ]; then
    printf '%s' "$text"
    return
  fi
  # Remove everything after the closing marker (inclusive)
  local inner="${after_open%%<<<END_DESIGN_PROJECT_BOUNDARY>>>*}"
  printf '%s' "$inner"
}

inner_content="$(_extract_inner "$boundary")"

# If inner content is empty or too short, nothing can match
if [ ${#inner_content} -lt "$MIN_MATCH_LENGTH" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Sliding-window verbatim match
# ---------------------------------------------------------------------------

# Check whether any substring of the candidate notes of length >= threshold
# appears verbatim in the inner boundary content.
#
# Strategy: slide a window of MIN_MATCH_LENGTH across the candidate text
# and check each window against the inner content.

candidate_len=${#candidate}

if [ "$candidate_len" -lt "$MIN_MATCH_LENGTH" ]; then
  # Candidate is shorter than the threshold — cannot match
  exit 0
fi

i=0
while [ $((i + MIN_MATCH_LENGTH)) -le "$candidate_len" ]; do
  window="${candidate:$i:$MIN_MATCH_LENGTH}"
  case "$inner_content" in
    *"$window"*)
      printf 'verdict-provenance-check.sh: verbatim match found — candidate notes contain a %d-char substring from the project boundary content\n' "$MIN_MATCH_LENGTH" >&2
      if [ "${DESIGN_REVIEW_VERDICT_TRACE:-}" = "1" ]; then
        printf 'verdict-provenance-check.sh: matched provenance window at offset %d: "%s"\n' "$i" "$window" >&2
      fi
      exit 1
      ;;
  esac
  i=$((i + 1))
done

exit 0
