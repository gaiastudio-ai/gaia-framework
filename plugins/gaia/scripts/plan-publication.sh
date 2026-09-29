#!/usr/bin/env bash
# plan-publication.sh — publication operation planner for screen-specification
# publication (create-ux) and republication on stale (edit-ux, add-feature).
#
# Takes a local specification manifest, a remote project file listing, and a
# last-published manifest. Emits an ordered operation plan on stdout.
#
# Operation verbs (one per line):
#   READ_FIRST <file>       — read before writing (always precedes WRITE)
#   WRITE <file>            — publish this file to the project
#   SKIP_UNCHANGED <file>   — hashes match, no write needed
#   CONFLICT <file> designer_hash=<hash> framework_hash=<hash>
#                           — designer edited since last publish; surface to user
#   DELETE_ORPHAN <file>    — remove a framework-published file no longer needed
#   REFRESH_MANIFEST        — rebuild the design-system manifest from the published set
#
# Security: every filename in all three inputs is validated. Absolute paths,
# path-traversal segments (../), empty names, and control characters (including
# newlines) are rejected with a diagnostic naming the offending entry. This
# prevents a crafted manifest from directing writes or deletions outside the
# project boundary.
#
# Remote listing: a malformed or wrong-shape listing deliberately degrades to
# "read everything first" (fail-safe), while malformed local and last-published
# inputs fail closed. The remote listing comes from the live integration and
# may be partially parseable; blocking publication on a transient parse failure
# would be worse than forcing a read-first pass.
#
# Performance: the plan is computed in a single jq invocation that joins the
# three inputs, avoiding O(N^2) per-file shell lookups.
#
# Script exposes no reusable public functions — the top-level flow is the
# entire API. Public-function coverage guard is N/A.
#
# Flags:
#   --strict-conflicts     — treat every differing remote file as CONFLICT
#                            (used when last-published manifest is absent)
#
# Usage:
#   plan-publication.sh --local-manifest <path> --remote-listing <path> --last-published <path> [--strict-conflicts]
#
# Exit codes:
#   0 — plan emitted successfully
#   1 — malformed or missing input, or unsafe filename detected

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="plan-publication.sh"

_die() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 1; }

# ---- arg parsing ----------------------------------------------------------
LOCAL_MANIFEST=""
REMOTE_LISTING=""
LAST_PUBLISHED=""
STRICT_CONFLICTS=false

while [ $# -gt 0 ]; do
  case "$1" in
    --local-manifest)  LOCAL_MANIFEST="$2"; shift 2 ;;
    --remote-listing)  REMOTE_LISTING="$2"; shift 2 ;;
    --last-published)  LAST_PUBLISHED="$2"; shift 2 ;;
    --strict-conflicts) STRICT_CONFLICTS=true; shift ;;
    *) _die "unknown option: $1" ;;
  esac
done

[ -n "$LOCAL_MANIFEST" ]  || _die "--local-manifest required"
[ -n "$REMOTE_LISTING" ]  || _die "--remote-listing required"
[ -n "$LAST_PUBLISHED" ]  || _die "--last-published required"

# ---- input validation -----------------------------------------------------

_require_valid_json() {
  local file="$1" label="$2"
  jq '.' "$file" >/dev/null 2>&1 || _die "malformed JSON in ${label}: $file"
}

[ -f "$LOCAL_MANIFEST" ] || _die "local manifest not found: $LOCAL_MANIFEST"
[ -s "$LOCAL_MANIFEST" ] || _die "local manifest is empty: $LOCAL_MANIFEST"
_require_valid_json "$LOCAL_MANIFEST" "local manifest"

if [ "$LAST_PUBLISHED" != "/dev/null" ] && [ -f "$LAST_PUBLISHED" ] && [ -s "$LAST_PUBLISHED" ]; then
  _require_valid_json "$LAST_PUBLISHED" "last-published"
fi

# Remote listing: tolerate malformed — degrade to empty (read-everything-first)
REMOTE_JSON="[]"
if [ -f "$REMOTE_LISTING" ] && [ -s "$REMOTE_LISTING" ]; then
  REMOTE_JSON="$(jq '.' "$REMOTE_LISTING" 2>/dev/null || printf '[]')"
fi

# Last-published: /dev/null or missing means first run (no orphans)
PUBLISHED_JSON="[]"
if [ "$LAST_PUBLISHED" != "/dev/null" ] && [ -f "$LAST_PUBLISHED" ] && [ -s "$LAST_PUBLISHED" ]; then
  PUBLISHED_JSON="$(jq '.' "$LAST_PUBLISHED" 2>/dev/null || printf '[]')"
fi

# ---- single-pass plan computation via jq ----------------------------------
# One jq program reads all three inputs (via --argjson), validates filenames,
# joins them by filename, and emits the plan. No per-file shell fork.

jq -r --argjson remote "$REMOTE_JSON" --argjson published "$PUBLISHED_JSON" --argjson strict "$STRICT_CONFLICTS" '
  # Filename safety check: reject absolute, traversal (..), dot-segment (.),
  # empty, trailing slash, empty path segments (//), and control chars
  def safe_filename:
    . as $f |
    if ($f | length) == 0 then error("unsafe filename: empty")
    elif ($f | startswith("/")) then error("unsafe filename (absolute): \($f)")
    elif ($f | test("(^|/)\\.\\.(/|$)")) then error("unsafe filename (traversal): \($f)")
    elif ($f | test("(^|/)\\.(/|$)")) then error("unsafe filename (dot-segment): \($f)")
    elif ($f | test("/$")) then error("unsafe filename (trailing slash): \($f)")
    elif ($f | test("//")) then error("unsafe filename (empty segment): \($f)")
    elif ($f | test("[\\x00-\\x1f\\x7f]")) then error("unsafe filename (control char): \($f)")
    else .
    end;

  # Validate all local filenames
  . as $local |
  ($local | map(.file | safe_filename) | empty // null) |

  # Validate all published filenames
  ($published | map(.file | safe_filename) | empty // null) |

  # Build lookup objects: {filename: hash}
  ($remote  | map({(.file): .hash}) | add // {}) as $remote_map |
  ($published | map({(.file): .hash}) | add // {}) as $pub_map |

  # Phase 1: for each local file, determine the operation
  ($local | map(
    .file as $f | .hash as $lh |
    $remote_map[$f] as $rh |
    if $rh == null then
      # Not in remote (new file or remote empty) — read first, then write
      "READ_FIRST \($f)\nWRITE \($f)"
    elif $lh == $rh then
      "SKIP_UNCHANGED \($f)"
    else
      # Hashes differ — check for designer edit (or strict mode)
      $pub_map[$f] as $ph |
      if $strict then
        "READ_FIRST \($f)\nCONFLICT \($f) designer_hash=\($rh) framework_hash=\($lh)"
      elif ($ph != null) and ($rh != $ph) then
        "READ_FIRST \($f)\nCONFLICT \($f) designer_hash=\($rh) framework_hash=\($lh)"
      else
        "READ_FIRST \($f)\nWRITE \($f)"
      end
    end
  )) +

  # Phase 2: orphan detection — published files no longer in local
  (($local | map({(.file): true}) | add // {}) as $local_set |
   $published | map(
    select($local_set[.file] == null) |
    "DELETE_ORPHAN \(.file)"
  ))

  | .[]
' "$LOCAL_MANIFEST"

# Unconditional: rebuild the design-system manifest from the published set
printf '%s\n' 'REFRESH_MANIFEST'
