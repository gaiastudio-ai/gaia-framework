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
# Comparison is case-insensitive and whitespace-normalised (runs of
# whitespace, including newlines, collapsed to a single space).
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

# Minimum substring length to trigger a match.  Raised from 20 to 40 to
# prevent false-positive denial of service: an attacker who controls
# design content could plant common reviewer phrases so that legitimate
# verdicts get rejected.  At 40 characters, common short sentences
# ("the layout is well structured") pass through, while verbatim
# paragraph-level copying is still caught.
MIN_MATCH_LENGTH=40

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
# Linear-time verbatim match with normalisation
# ---------------------------------------------------------------------------
#
# Strategy: a python3 invocation that
#   1. Reads both texts from temp files, normalises each (lowercase,
#      collapse whitespace).
#   2. Slides a window of MIN_MATCH_LENGTH across the candidate and
#      checks each window against the normalised boundary via Python's
#      O(N) `in` operator (CPython uses a fast Boyer-Moore variant).
#
# Complexity: O(N * L) where N = candidate length, L = window length,
# with each `in` check amortised to near-linear — well under 1 s for
# the 10 KB-vs-200 KB workload that times out in the old bash loop.
#
# Data flows through temp files to avoid large shell argument passing.

command -v python3 >/dev/null 2>&1 || _die "python3 is required but not found on PATH"

_tmp_boundary="$(mktemp)"
_tmp_candidate="$(mktemp)"
trap 'rm -f "$_tmp_boundary" "$_tmp_candidate"' EXIT

printf '%s' "$inner_content" > "$_tmp_boundary"
printf '%s' "$candidate" > "$_tmp_candidate"

result="$(python3 -c '
import re, sys

min_len = int(sys.argv[1])
trace = sys.argv[2] == "1"
boundary_file = sys.argv[3]
candidate_file = sys.argv[4]

with open(boundary_file) as f:
    boundary = f.read()
with open(candidate_file) as f:
    candidate = f.read()

# Normalise: lowercase, collapse whitespace to single space, strip edges
boundary = re.sub(r"\s+", " ", boundary.lower()).strip()
candidate = re.sub(r"\s+", " ", candidate.lower()).strip()

blen = len(boundary)
clen = len(candidate)

if blen < min_len or clen < min_len:
    print("PASS")
    sys.exit(0)

# Slide window across candidate and check against boundary
for j in range(clen - min_len + 1):
    w = candidate[j:j + min_len]
    if w in boundary:
        if trace:
            print(f"MATCH:{j}:{w}")
        else:
            print(f"MATCH:{j}")
        sys.exit(0)

print("PASS")
' "$MIN_MATCH_LENGTH" "${DESIGN_REVIEW_VERDICT_TRACE:-0}" "$_tmp_boundary" "$_tmp_candidate")"

case "$result" in
  PASS)
    exit 0
    ;;
  MATCH:*)
    offset="${result#MATCH:}"
    offset="${offset%%:*}"
    printf 'verdict-provenance-check.sh: verbatim match found — candidate notes contain a %d-char substring from the project boundary content\n' "$MIN_MATCH_LENGTH" >&2
    if [ "${DESIGN_REVIEW_VERDICT_TRACE:-}" = "1" ]; then
      matched_window="${result#*MATCH:*:}"
      if [ "$matched_window" != "$result" ] && [ -n "$matched_window" ]; then
        printf 'verdict-provenance-check.sh: matched provenance window at offset %s: "%s"\n' "$offset" "$matched_window" >&2
      fi
    fi
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
