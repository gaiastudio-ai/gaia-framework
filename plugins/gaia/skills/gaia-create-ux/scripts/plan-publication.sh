#!/usr/bin/env bash
# plan-publication.sh — publication operation planner for /gaia-create-ux.
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
#
# Script exposes no reusable public functions — the top-level flow is the
# entire API. Public-function coverage guard is N/A.
#
# Usage:
#   plan-publication.sh --local-manifest <path> --remote-listing <path> --last-published <path>
#
# Exit codes:
#   0 — plan emitted successfully
#   1 — malformed or missing input

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="plan-publication.sh"

_die() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 1; }

# ---- arg parsing ----------------------------------------------------------
LOCAL_MANIFEST=""
REMOTE_LISTING=""
LAST_PUBLISHED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --local-manifest)  LOCAL_MANIFEST="$2"; shift 2 ;;
    --remote-listing)  REMOTE_LISTING="$2"; shift 2 ;;
    --last-published)  LAST_PUBLISHED="$2"; shift 2 ;;
    *) _die "unknown option: $1" ;;
  esac
done

[ -n "$LOCAL_MANIFEST" ]  || _die "--local-manifest required"
[ -n "$REMOTE_LISTING" ]  || _die "--remote-listing required"
[ -n "$LAST_PUBLISHED" ]  || _die "--last-published required"

# ---- input validation -----------------------------------------------------

# _require_valid_json FILE LABEL — die with a diagnostic when FILE is not
# parseable JSON. Centralises the jq-validation pattern (three call sites).
_require_valid_json() {
  local file="$1" label="$2"
  jq '.' "$file" >/dev/null 2>&1 || _die "malformed JSON in ${label}: $file"
}

# Local manifest must exist, be non-empty, and be valid JSON
[ -f "$LOCAL_MANIFEST" ] || _die "local manifest not found: $LOCAL_MANIFEST"
[ -s "$LOCAL_MANIFEST" ] || _die "local manifest is empty: $LOCAL_MANIFEST"
_require_valid_json "$LOCAL_MANIFEST" "local manifest"

# Last-published: /dev/null is the first-run case (zero orphans); any other
# path must be valid JSON if non-empty.
if [ "$LAST_PUBLISHED" != "/dev/null" ] && [ -f "$LAST_PUBLISHED" ] && [ -s "$LAST_PUBLISHED" ]; then
  _require_valid_json "$LAST_PUBLISHED" "last-published"
fi

# Remote listing: a malformed or wrong-shape listing deliberately degrades to
# "read everything first" (fail-safe), while malformed local and last-published
# inputs fail closed. The remote listing comes from the live integration and
# may be partially parseable; blocking publication on a transient parse failure
# would be worse than forcing a read-first pass.
# Remote listing may be empty (triggers READ_FIRST for all files)
REMOTE_EMPTY=0
if [ ! -f "$REMOTE_LISTING" ] || [ ! -s "$REMOTE_LISTING" ]; then
  REMOTE_EMPTY=1
else
  jq '.' "$REMOTE_LISTING" >/dev/null 2>&1 || true  # tolerate; treated as empty
fi

# ---- build lookup tables via jq ------------------------------------------

# Read local files into a newline-delimited "file\thash" list
LOCAL_FILES="$(jq -r '.[] | "\(.file)\t\(.hash)"' "$LOCAL_MANIFEST")"

# Read remote files (if present)
REMOTE_FILES=""
if [ "$REMOTE_EMPTY" -eq 0 ]; then
  REMOTE_FILES="$(jq -r '.[] | "\(.file)\t\(.hash)"' "$REMOTE_LISTING" 2>/dev/null || true)"
fi

# Read last-published files (if present)
PUBLISHED_FILES=""
if [ "$LAST_PUBLISHED" != "/dev/null" ] && [ -f "$LAST_PUBLISHED" ] && [ -s "$LAST_PUBLISHED" ]; then
  PUBLISHED_FILES="$(jq -r '.[] | "\(.file)\t\(.hash)"' "$LAST_PUBLISHED" 2>/dev/null || true)"
fi

# ---- helper: lookup hash by filename in a tab-delimited list ---------------
_lookup_hash() {
  local filename="$1" list="$2"
  printf '%s\n' "$list" | awk -F'\t' -v f="$filename" '$1 == f { print $2; exit }'
}

# ---- emit the operation plan -----------------------------------------------

# Phase 1: for each local file, determine the operation
while IFS=$'\t' read -r local_file local_hash; do
  [ -n "$local_file" ] || continue

  if [ "$REMOTE_EMPTY" -eq 1 ]; then
    # Remote unknown — must read first before anything
    printf 'READ_FIRST %s\n' "$local_file"
    printf 'WRITE %s\n' "$local_file"
    continue
  fi

  remote_hash="$(_lookup_hash "$local_file" "$REMOTE_FILES")"

  if [ -z "$remote_hash" ]; then
    # New file, not in remote — still read first (the listing may be stale)
    printf 'READ_FIRST %s\n' "$local_file"
    printf 'WRITE %s\n' "$local_file"
    continue
  fi

  # File exists in remote — check if unchanged
  if [ "$local_hash" = "$remote_hash" ]; then
    printf 'SKIP_UNCHANGED %s\n' "$local_file"
    continue
  fi

  # Hashes differ — check if designer edited (remote differs from last-published)
  published_hash="$(_lookup_hash "$local_file" "$PUBLISHED_FILES")"

  printf 'READ_FIRST %s\n' "$local_file"

  if [ -n "$published_hash" ] && [ "$remote_hash" != "$published_hash" ]; then
    # Designer changed the file since our last publish
    printf 'CONFLICT %s designer_hash=%s framework_hash=%s\n' "$local_file" "$remote_hash" "$local_hash"
  else
    # Remote matches what we last published (or was never published) — safe to write
    printf 'WRITE %s\n' "$local_file"
  fi
done <<< "$LOCAL_FILES"

# Phase 2: orphan detection — files we published that are no longer local
if [ -n "$PUBLISHED_FILES" ]; then
  while IFS=$'\t' read -r pub_file _pub_hash; do
    [ -n "$pub_file" ] || continue
    # Check if still in local manifest
    in_local="$(_lookup_hash "$pub_file" "$LOCAL_FILES")"
    if [ -z "$in_local" ]; then
      printf 'DELETE_ORPHAN %s\n' "$pub_file"
    fi
  done <<< "$PUBLISHED_FILES"
fi
