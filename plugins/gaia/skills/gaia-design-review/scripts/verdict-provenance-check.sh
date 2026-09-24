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
# Usage:
#   verdict-provenance-check.sh --notes-file <path> --boundary-file <path>
#
# Both files must exist and be non-empty.  Inputs are read from files
# (not argv) so that large design read-backs do not hit the Linux
# MAX_ARG_STRLEN (128 KB) per-argument limit.
#
# Exit codes:
#   0  — notes text passes the provenance check (no verbatim match)
#   1  — notes text contains a verbatim match from the boundary content
#   2  — argument error (missing, unreadable, or empty file)

_die() { printf 'verdict-provenance-check.sh: %s\n' "$1" >&2; exit 2; }

# Minimum substring length to trigger a match.  Raised from 20 to 40 to
# prevent false-positive denial of service: an attacker who controls
# design content could plant common reviewer phrases so that legitimate
# verdicts get rejected.  At 40 characters, common short sentences
# ("the layout is well structured") pass through, while verbatim
# paragraph-level copying is still caught.
MIN_MATCH_LENGTH=40

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

notes_file=""
boundary_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file)
      [ $# -ge 2 ] || _die "--notes-file requires a path argument"
      notes_file="$2"; shift 2 ;;
    --boundary-file)
      [ $# -ge 2 ] || _die "--boundary-file requires a path argument"
      boundary_file="$2"; shift 2 ;;
    *)
      _die "unknown argument: $1 — usage: verdict-provenance-check.sh --notes-file <path> --boundary-file <path>" ;;
  esac
done

[ -n "$notes_file" ]    || _die "missing --notes-file"
[ -n "$boundary_file" ] || _die "missing --boundary-file"
[ -f "$notes_file" ]    || _die "notes file not found: $notes_file"
[ -r "$notes_file" ]    || _die "notes file not readable: $notes_file"
[ -f "$boundary_file" ] || _die "boundary file not found: $boundary_file"
[ -r "$boundary_file" ] || _die "boundary file not readable: $boundary_file"
[ -s "$notes_file" ]    || _die "notes file is empty: $notes_file"
[ -s "$boundary_file" ] || _die "boundary file is empty: $boundary_file"

# ---------------------------------------------------------------------------
# Extract content between boundary markers (strip the markers themselves)
# ---------------------------------------------------------------------------
# Writes the stripped inner content to a temp file, avoiding large shell
# variables entirely.

command -v python3 >/dev/null 2>&1 || _die "python3 is required but not found on PATH"

_tmp_inner="$(mktemp)"
trap 'rm -f "$_tmp_inner"' EXIT

python3 -c '
import sys

boundary_file = sys.argv[1]
out_file = sys.argv[2]

with open(boundary_file) as f:
    text = f.read()

OPEN  = "<<<DESIGN_PROJECT_BOUNDARY>>>"
CLOSE = "<<<END_DESIGN_PROJECT_BOUNDARY>>>"

start = text.find(OPEN)
if start == -1:
    inner = text
else:
    after = text[start + len(OPEN):]
    end = after.find(CLOSE)
    inner = after[:end] if end != -1 else after

with open(out_file, "w") as f:
    f.write(inner)
' "$boundary_file" "$_tmp_inner"

# If inner content is too short, nothing can match
_inner_len="$(wc -c < "$_tmp_inner" | tr -d ' ')"
if [ "$_inner_len" -lt "$MIN_MATCH_LENGTH" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Linear-time verbatim match with normalisation
# ---------------------------------------------------------------------------
#
# Strategy: a python3 invocation that
#   1. Reads both texts from files, normalises each (lowercase,
#      collapse whitespace).
#   2. Slides a window of MIN_MATCH_LENGTH across the candidate and
#      checks each window against the normalised boundary via Python's
#      O(N) `in` operator (CPython uses a fast Boyer-Moore variant).
#
# Complexity: O(N * L) where N = candidate length, L = window length,
# with each `in` check amortised to near-linear — well under 1 s for
# the 10 KB-vs-200 KB workload.

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
' "$MIN_MATCH_LENGTH" "${DESIGN_REVIEW_VERDICT_TRACE:-0}" "$_tmp_inner" "$notes_file")"

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
