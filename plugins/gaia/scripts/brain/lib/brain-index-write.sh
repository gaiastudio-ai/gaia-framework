#!/usr/bin/env bash
# brain-index-write.sh — atomic brain-index writer (shared between feed and
# unfeed so the sibling-tempfile -> validate -> mv idiom cannot drift).
#
# SOURCEABLE ONLY — never execute directly.
#
# Exports (prefixed _biw_ to avoid namespace collision):
#   _biw_atomic_write MANIFEST TMPFILE_CONTENT_CB
#     Takes the manifest path and writes an updated manifest atomically:
#     1. Caller provides the new content in a tempfile.
#     2. This helper validates the tempfile against the brain-index schema.
#     3. On validation success (exit 0 or 3), renames into place.
#     4. On any other exit, removes the tempfile and preserves the prior manifest.
#
#   _biw_register_entry MANIFEST SLUG REL_PATH TAG_LIST SYNOPSIS CONFIDENCE
#                       CONTENT_HASH SOURCE_URL FETCHED_AT EXPIRES_AT TITLE
#     Add/replace an ingested entry. Returns 0 on success, 1 on validation failure.
#
#   _biw_deregister_entry MANIFEST SLUG
#     Remove an ingested entry by slug (only source_type: ingested). Returns 0
#     on success, 1 on validation failure, 2 on no matching entry.
#
# Portability: bash 3.2 (macOS default) clean. LC_ALL=C.

# Idempotent source guard.
if [ "${_BIW_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi

_biw_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# The validator lives one level up from lib/.
_BIW_VALIDATE="${_BIW_VALIDATE_OVERRIDE:-$_biw_self_dir/../validate-brain-index.sh}"

# _biw_atomic_write MANIFEST TMPFILE — validate tmpfile, rename on success.
# Returns 0 on success, 1 on validation failure.
_biw_atomic_write() {
  local manifest="$1"
  local tmpfile="$2"

  if [ ! -f "$tmpfile" ]; then
    printf 'brain-index-write.sh: tmpfile does not exist: %s\n' "$tmpfile" >&2
    return 1
  fi

  # Validate the tempfile BEFORE renaming into place.
  # Unset _GAIA_PATHS_LOADED so the validator's subprocess re-sources
  # gaia-paths.sh fresh.
  local val_rc=0
  env -u _GAIA_PATHS_LOADED bash "$_BIW_VALIDATE" "$tmpfile" || val_rc=$?
  case "$val_rc" in
    0|3)
      # 0=valid, 3=schema backend unavailable (structural check skipped).
      mv "$tmpfile" "$manifest"
      ;;
    *)
      printf 'brain-index-write.sh: validation failed (exit %d); prior manifest preserved\n' "$val_rc" >&2
      rm -f "$tmpfile"
      return 1
      ;;
  esac

  return 0
}

# _biw_register_entry — add or replace an ingested entry in the manifest.
_biw_register_entry() {
  local manifest="$1"
  local slug="$2"
  local rel_path="$3"
  local tag_list="$4"
  local synopsis="$5"
  local confidence="$6"
  local content_hash="$7"
  local source_url="$8"
  local fetched_at="$9"
  local expires_at="${10}"
  local title="${11:-}"

  if [ ! -f "$manifest" ]; then
    printf 'brain-index-write.sh: manifest not found: %s\n' "$manifest" >&2
    return 1
  fi

  # Build the new entry YAML (used by awk fallback).
  local entry
  entry="$(cat <<ENTRY
  - key: "$slug"
    source_type: ingested
    path: "$rel_path"
    tags: ["$tag_list"]
    synopsis: "$synopsis"
    edges: []
    trust:
      confidence: $confidence
      content_hash: "$content_hash"
      source_url: ${source_url:-null}
      fetched_at: ${fetched_at:-null}
      expires_at: ${expires_at:-null}
ENTRY
)"

  # Use .yaml suffix so the validator recognizes the extension.
  local tmpfile="${manifest}.tmp.$$.yaml"

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$manifest" "$slug" "$rel_path" "$tag_list" "$synopsis" \
      "$confidence" "$content_hash" "${source_url:-}" "${fetched_at:-}" "${expires_at:-}" \
      "$tmpfile" <<'PYEOF'
import sys, yaml

manifest_path = sys.argv[1]
slug = sys.argv[2]
rel_path = sys.argv[3]
tag_list_str = sys.argv[4]
synopsis = sys.argv[5]
confidence = float(sys.argv[6])
content_hash = sys.argv[7]
source_url = sys.argv[8] if sys.argv[8] else None
fetched_at = sys.argv[9] if sys.argv[9] else None
expires_at = sys.argv[10] if sys.argv[10] else None
tmpfile = sys.argv[11]

with open(manifest_path) as f:
    doc = yaml.safe_load(f) or {}

entries = doc.get("entries") or []
# Remove existing entry with same key.
entries = [e for e in entries if e.get("key") != slug]

tags = [t.strip().strip('"') for t in tag_list_str.split(",")]
new_entry = {
    "key": slug,
    "source_type": "ingested",
    "path": rel_path,
    "tags": tags,
    "synopsis": synopsis,
    "edges": [],
    "trust": {
        "confidence": confidence,
        "content_hash": content_hash,
        "source_url": source_url,
        "fetched_at": fetched_at,
        "expires_at": expires_at,
    },
}
entries.append(new_entry)
doc["entries"] = entries
doc["schema_version"] = 1

with open(tmpfile, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PYEOF
  else
    # Fallback: awk-based append.
    cp "$manifest" "$tmpfile"
    if grep -q '^entries: \[\]' "$tmpfile"; then
      sed -i.bak 's/^entries: \[\]/entries:/' "$tmpfile"
      rm -f "${tmpfile}.bak"
    fi
    printf '%s\n' "$entry" >> "$tmpfile"
  fi

  _biw_atomic_write "$manifest" "$tmpfile"
  return $?
}

# _biw_deregister_entry — remove an ingested entry by slug.
# Only removes entries with source_type: ingested. Entries with other
# source_type values sharing the same key are preserved.
# Returns 0 on success, 1 on validation failure, 2 on no matching ingested entry.
_biw_deregister_entry() {
  local manifest="$1"
  local slug="$2"

  if [ ! -f "$manifest" ]; then
    printf 'brain-index-write.sh: manifest not found: %s\n' "$manifest" >&2
    return 1
  fi

  local tmpfile="${manifest}.tmp.$$.yaml"

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    local py_rc=0
    python3 - "$manifest" "$slug" "$tmpfile" <<'PYEOF' || py_rc=$?
import sys, yaml

manifest_path = sys.argv[1]
slug = sys.argv[2]
tmpfile = sys.argv[3]

with open(manifest_path) as f:
    doc = yaml.safe_load(f) or {}

entries = doc.get("entries") or []

# Find and remove only the ingested entry matching the slug.
found = False
new_entries = []
for e in entries:
    if e.get("key") == slug and e.get("source_type") == "ingested":
        found = True
        continue
    new_entries.append(e)

if not found:
    sys.exit(2)

doc["entries"] = new_entries
doc["schema_version"] = 1

with open(tmpfile, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PYEOF
    if [ "$py_rc" -eq 2 ]; then
      rm -f "$tmpfile"
      return 2
    elif [ "$py_rc" -ne 0 ]; then
      rm -f "$tmpfile"
      return 1
    fi
  else
    # Fallback: awk-based removal for environments without python3+PyYAML.
    #
    # The awk must match by key AND source_type: ingested. An entry block
    # starts at "  - key:" and includes all subsequent lines until the next
    # "  - key:" or EOF. We buffer each block, inspect it for the slug AND
    # source_type: ingested, and only drop the block that matches both.
    # Blocks with the same key but a different source_type are emitted.
    awk -v slug="$slug" '
      BEGIN { in_block=0; buf=""; is_target=0; is_ingested=0; found=0 }

      /^  - key:/ {
        # Flush the previous block.
        if (in_block) {
          if (is_target && is_ingested) {
            found = 1   # drop this block
          } else {
            printf "%s", buf
          }
        }
        # Start a new block.
        in_block = 1
        buf = $0 "\n"
        is_target = ($0 ~ "key: \"" slug "\"") ? 1 : 0
        is_ingested = 0
        next
      }

      in_block {
        buf = buf $0 "\n"
        if ($0 ~ /^    source_type: ingested/) {
          is_ingested = 1
        }
        next
      }

      # Lines before the first entry block (preamble).
      { print }

      END {
        # Flush the last block.
        if (in_block) {
          if (is_target && is_ingested) {
            found = 1
          } else {
            printf "%s", buf
          }
        }
        if (!found) exit 2
      }
    ' "$manifest" > "$tmpfile"
    local awk_rc=$?
    if [ "$awk_rc" -eq 2 ]; then
      rm -f "$tmpfile"
      return 2
    fi
  fi

  _biw_atomic_write "$manifest" "$tmpfile"
  return $?
}

_BIW_LOADED=1
export _BIW_LOADED

return 0 2>/dev/null || true
