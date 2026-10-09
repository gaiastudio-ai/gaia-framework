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
# Security: every filename and hash in all three inputs is validated via the
# shared safe-filename lib. Absolute paths, path-traversal segments (../),
# empty names, control characters (including newlines and tabs) are rejected
# with a diagnostic naming the offending entry. This prevents a crafted
# manifest from directing writes or deletions outside the project boundary,
# and prevents a crafted hash from forging plan lines via newline injection.
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
#   --project <key>        — target project key (design_system | product_design;
#                            default: design_system)
#
# Usage:
#   plan-publication.sh --local-manifest <path> --remote-listing <path> --last-published <path> [--strict-conflicts] [--project <key>]
#
# Exit codes:
#   0 — plan emitted successfully
#   1 — malformed or missing input, or unsafe filename/hash detected

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="plan-publication.sh"

_die() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 1; }

# ---- source shared libs -----------------------------------------------------
_PLAN_PUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SAFE_FN_LIB="${_PLAN_PUB_DIR}/lib/safe-filename.sh"
if [ ! -f "$_SAFE_FN_LIB" ]; then
  _die "missing shared lib: $_SAFE_FN_LIB"
fi
# shellcheck source=lib/safe-filename.sh
. "$_SAFE_FN_LIB"

# ---- arg parsing ----------------------------------------------------------
LOCAL_MANIFEST=""
REMOTE_LISTING=""
LAST_PUBLISHED=""
STRICT_CONFLICTS=false
PROJECT="design_system"

while [ $# -gt 0 ]; do
  case "$1" in
    --local-manifest)  LOCAL_MANIFEST="$2"; shift 2 ;;
    --remote-listing)  REMOTE_LISTING="$2"; shift 2 ;;
    --last-published)  LAST_PUBLISHED="$2"; shift 2 ;;
    --strict-conflicts) STRICT_CONFLICTS=true; shift ;;
    --project)         PROJECT="$2"; shift 2 ;;
    *) _die "unknown option: $1" ;;
  esac
done

[ -n "$LOCAL_MANIFEST" ]  || _die "--local-manifest required"
[ -n "$REMOTE_LISTING" ]  || _die "--remote-listing required"
[ -n "$LAST_PUBLISHED" ]  || _die "--last-published required"

case "$PROJECT" in
  design_system|product_design) ;;
  *) _die "invalid --project value: $PROJECT (must be design_system or product_design)" ;;
esac

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

# Last-published: /dev/null or missing means first run (no orphans).
# Validate shape, normalise legacy flat-array to per-project object, then
# slice to target key. Valid shapes:
#   (a) flat array of {file, hash} objects (legacy)
#   (b) per-project object whose target entry is an object with array "files"
# Anything else (number, string, wrong-shape array, missing/non-array files)
# is a hard error — fail closed, never plan writes against corrupt state.
PUBLISHED_JSON="[]"
if [ "$LAST_PUBLISHED" != "/dev/null" ] && [ -f "$LAST_PUBLISHED" ] && [ -s "$LAST_PUBLISHED" ]; then
  # Shape validation (before normalisation)
  local_shape="$(jq -r --arg proj "$PROJECT" '
    if type == "array" then
      # Legacy flat: every element must be an object with .file
      if all(type == "object" and has("file")) then "legacy_array"
      else "invalid" end
    elif type == "object" then
      # Per-project: target key must be an object with array .files (or absent)
      if .[$proj] == null then "valid_object"
      elif (.[$proj] | type) != "object" then "invalid"
      elif (.[$proj] | has("files")) and ((.[$proj].files | type) != "array") then "invalid"
      elif (.[$proj] | has("files") | not) then "invalid"
      else "valid_object" end
    else "invalid" end
  ' "$LAST_PUBLISHED" 2>/dev/null)" || local_shape="invalid"

  if [ "$local_shape" = "invalid" ]; then
    _die "invalid state file shape: $LAST_PUBLISHED (expected a flat array of {file,hash} objects or a per-project object with array files)"
  fi

  PUBLISHED_JSON="$(jq --arg proj "$PROJECT" '
    # Detect shape: array = legacy flat, object = per-project
    if type == "array" then
      # Legacy: wrap under design_system
      {"design_system": {"reference": null, "last_published_at": null, "files": .},
       "product_design": {"reference": null, "last_published_at": null, "files": []}}
    else . end
    | .[$proj].files // []
  ' "$LAST_PUBLISHED")" || _die "failed to read state file: $LAST_PUBLISHED"
fi

# ---- auto-strict on absent baseline with non-empty remote -------------------
# When we have no publication record for this project (PUBLISHED_JSON is empty)
# AND the remote already has files, every differing remote file must be a
# CONFLICT so the user can resolve it — plain WRITEs would silently overwrite
# designer work. First-publication to an empty remote is unaffected.
if [ "$STRICT_CONFLICTS" = false ] && [ "$PUBLISHED_JSON" = "[]" ]; then
  _has_remote_files="$(printf '%s' "$REMOTE_JSON" | jq 'length > 0')"
  if [ "$_has_remote_files" = "true" ]; then
    STRICT_CONFLICTS=true
  fi
fi

# ---- single-pass plan computation via jq ----------------------------------
# One jq program reads all three inputs (via --argjson), validates filenames
# and hashes, joins them by filename, and emits the plan. No per-file shell fork.

jq -r --argjson remote "$REMOTE_JSON" --argjson published "$PUBLISHED_JSON" --argjson strict "$STRICT_CONFLICTS" "
  $SAFE_FILENAME_JQ_DEF
  $SAFE_HASH_JQ_DEF

  # Validate all local filenames and hashes
  . as \$local |
  (\$local | map(.file | safe_filename) | empty // null) |
  (\$local | map(.hash | safe_hash) | empty // null) |

  # Validate all published filenames and hashes
  (\$published | map(.file | safe_filename) | empty // null) |
  (\$published | map(.hash | safe_hash) | empty // null) |

  # Validate remote hashes (filenames already validated above pattern)
  (\$remote | map(select(.hash != null) | .hash | safe_hash) | empty // null) |

  # Build lookup objects: {filename: hash}
  (\$remote  | map({(.file): .hash}) | add // {}) as \$remote_map |
  (\$published | map({(.file): .hash}) | add // {}) as \$pub_map |

  # Phase 1: for each local file, determine the operation
  (\$local | map(
    .file as \$f | .hash as \$lh |
    \$remote_map[\$f] as \$rh |
    if \$rh == null then
      # Not in remote (new file or remote empty) — read first, then write
      \"READ_FIRST \(\$f)\nWRITE \(\$f)\"
    elif \$lh == \$rh then
      \"SKIP_UNCHANGED \(\$f)\"
    else
      # Hashes differ — check for designer edit (or strict mode)
      \$pub_map[\$f] as \$ph |
      if \$strict then
        \"READ_FIRST \(\$f)\nCONFLICT \(\$f) designer_hash=\(\$rh) framework_hash=\(\$lh)\"
      elif (\$ph != null) and (\$rh != \$ph) then
        \"READ_FIRST \(\$f)\nCONFLICT \(\$f) designer_hash=\(\$rh) framework_hash=\(\$lh)\"
      else
        \"READ_FIRST \(\$f)\nWRITE \(\$f)\"
      end
    end
  )) +

  # Phase 2: orphan detection — published files no longer in local
  ((\$local | map({(.file): true}) | add // {}) as \$local_set |
   \$published | map(
    select(\$local_set[.file] == null) |
    \"DELETE_ORPHAN \(.file)\"
  ))

  | .[]
" "$LOCAL_MANIFEST"

# Unconditional: rebuild the design-system manifest from the published set
printf '%s\n' 'REFRESH_MANIFEST'
