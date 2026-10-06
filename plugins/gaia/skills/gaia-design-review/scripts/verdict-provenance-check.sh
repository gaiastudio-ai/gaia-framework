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
#   2  — argument error (missing, unreadable, or empty file),
#        or malformed boundary file (unmatched marker, missing marker)

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

# Dual marker pairs
MARKER_PAIRS = [
    ("<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>",  "<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>"),
    ("<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>", "<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>"),
]

# Check that at least one marker of either type exists
has_any = False
for open_m, close_m in MARKER_PAIRS:
    if open_m in text or close_m in text:
        has_any = True
        break

if not has_any:
    sys.stderr.write("verdict-provenance-check.sh: boundary file contains no markers of either type\n")
    sys.exit(2)

# Extract ALL regions for both marker types.
# Pair the i-th OPEN with the i-th CLOSE for each marker type (index-based
# matching). This makes the extraction resilient to an embedded close marker
# inside region content (the defence is at write time via the shared escape,
# but a wider extraction is safer for checking).
regions = []
for open_m, close_m in MARKER_PAIRS:
    # Collect all positions of OPENs and CLOSEs
    opens = []
    closes = []
    pos = 0
    while True:
        idx = text.find(open_m, pos)
        if idx == -1:
            break
        opens.append(idx)
        pos = idx + len(open_m)
    pos = 0
    while True:
        idx = text.find(close_m, pos)
        if idx == -1:
            break
        closes.append(idx)
        pos = idx + len(close_m)

    if len(opens) == 0 and len(closes) == 0:
        continue  # no markers of this type

    # Unmatched: more opens than closes
    if len(opens) > len(closes):
        sys.stderr.write(
            "verdict-provenance-check.sh: unmatched open marker (no matching close): %s\n" % open_m
        )
        sys.exit(2)

    # Unmatched: closes with no opens
    if len(opens) == 0 and len(closes) > 0:
        sys.stderr.write(
            "verdict-provenance-check.sh: unmatched close marker (no matching open): %s\n" % close_m
        )
        sys.exit(2)

    # Pair i-th OPEN with the i-th CLOSE. When the counts match,
    # pairing is direct (opens[i] with closes[i]). When there are
    # extra closes, the surplus are treated as embedded markers
    # (the defence is at write time via the shared escape).
    n_opens = len(opens)
    n_closes = len(closes)
    offset = n_closes - n_opens  # extra closes consumed as embedded markers

    for i in range(n_opens):
        o_pos = opens[i]
        c_idx = offset + i  # pair with the (offset+i)-th close
        c_pos = closes[c_idx]
        after_open = o_pos + len(open_m)
        if c_pos < after_open:
            sys.stderr.write(
                "verdict-provenance-check.sh: malformed boundary file — "
                "close marker before its open marker: %s\n" % close_m
            )
            sys.exit(2)
        region_text = text[after_open:c_pos]
        # Check for nested open markers of ANY type inside the region
        for other_open, _ in MARKER_PAIRS:
            if other_open in region_text:
                sys.stderr.write(
                    "verdict-provenance-check.sh: malformed boundary file — "
                    "nested open marker %s inside an open %s region\n" % (other_open, open_m)
                )
                sys.exit(2)
        regions.append(region_text)

inner = "\n".join(regions)

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
#   1. Reads both texts from files, normalises each (NFKC + casefold,
#      collapse whitespace).
#   2. Slides a window of MIN_MATCH_LENGTH across the candidate and
#      checks each window against the normalised boundary via Python's
#      O(N) `in` operator (CPython uses a fast Boyer-Moore variant).
#
# Complexity: O(N * L) where N = candidate length, L = window length,
# with each `in` check amortised to near-linear — well under 1 s for
# the 10 KB-vs-200 KB workload.

_py_rc=0
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

# Normalise: NFKC + casefold, collapse whitespace to single space, strip edges
import unicodedata
def _norm(s):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", s).casefold()).strip()
boundary = _norm(boundary)
candidate = _norm(candidate)

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
' "$MIN_MATCH_LENGTH" "${DESIGN_REVIEW_VERDICT_TRACE:-0}" "$_tmp_inner" "$notes_file" 2>&1)" || _py_rc=$?

if [ "$_py_rc" -ne 0 ]; then
  printf 'verdict-provenance-check.sh: python3 comparison exited %d — failing closed\n' "$_py_rc" >&2
  exit 2
fi

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
    printf 'verdict-provenance-check.sh: unexpected comparison output — failing closed: %s\n' "$result" >&2
    exit 2
    ;;
esac
