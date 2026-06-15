#!/usr/bin/env bash
# gaia-knowledge-refresh.sh — hash-gated re-fetch lifecycle for ingested
# sources in the Brain knowledge layer.
#
# WHAT IT DOES
#   For each ingested entry in brain-index.yaml, re-fetches the source content,
#   computes the post-strip content hash, and applies a three-way reconcile:
#     - hash match  -> SKIP (no file write, no brain-index mutation)
#     - content diff -> overwrite ingested file (atomic), update entry
#     - fetch failure -> mark entry status: failed, PRESERVE stale file
#
# USAGE
#   gaia_knowledge_refresh [--fetched-content FILE]
#
#   --fetched-content FILE  A file containing the re-fetched content for ALL
#                           ingested sources. This is the test seam: tests
#                           provide the content directly, bypassing network.
#                           In production, the orchestration layer (SKILL.md)
#                           fetches each source via WebFetch and invokes the
#                           script per-entry or batched with pre-fetched files.
#
# SOURCEABLE + EXECUTABLE
#   When sourced, exports gaia_knowledge_refresh() and its helpers.
#   When executed directly, dispatches gaia_knowledge_refresh() with CLI args.
#
# SHARED LIB
#   Core fetch/strip/hash helpers come from brain/lib/ingest-common.sh (the
#   same library that gaia-feed.sh uses), so the two scripts never drift.
#
# Portability: bash 3.2 (macOS default) clean. LC_ALL=C. set -euo pipefail.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Source shared helpers
# ---------------------------------------------------------------------------
_gkr_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# shellcheck source=../lib/gaia-paths.sh
. "$_gkr_self_dir/../lib/gaia-paths.sh" || {
  printf 'gaia-knowledge-refresh.sh: could not source gaia-paths.sh\n' >&2
  return 1 2>/dev/null || exit 1
}

# shellcheck source=lib/ingest-common.sh
. "$_gkr_self_dir/lib/ingest-common.sh" || {
  printf 'gaia-knowledge-refresh.sh: could not source ingest-common.sh\n' >&2
  return 1 2>/dev/null || exit 1
}

# Sibling validator.
_GKR_VALIDATE="$_gkr_self_dir/validate-brain-index.sh"

# ---------------------------------------------------------------------------
# _gkr_enumerate_ingested MANIFEST — list ingested entries as tab-separated
# records: key, source_url, content_hash, path, ingest_source_kind.
# Uses python3+PyYAML when available, awk fallback for portability.
# ---------------------------------------------------------------------------
_gkr_enumerate_ingested() {
  local manifest="$1"

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$manifest" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
for e in (doc.get("entries") or []):
    if e.get("source_type") != "ingested":
        continue
    key = e.get("key", "")
    trust = e.get("trust") or {}
    src_url = trust.get("source_url") or ""
    chash = trust.get("content_hash") or ""
    path = e.get("path", "")
    # Infer ingest_source_kind from tags; default to url.
    tags = e.get("tags") or []
    kind = "url"
    for t in tags:
        if t in ("file", "stdin", "llms_txt"):
            kind = t
            break
    sys.stdout.write("%s\t%s\t%s\t%s\t%s\n" % (key, src_url, chash, path, kind))
PYEOF
  else
    # awk fallback: parse YAML entries by line scanning.
    awk '
      /^[[:space:]]*- key:/ {
        if (key != "" && st == "ingested") {
          printf "%s\t%s\t%s\t%s\t%s\n", key, src_url, chash, path, kind
        }
        key = ""; st = ""; src_url = ""; chash = ""; path = ""; kind = "url"
        val = $0; sub(/.*key:[[:space:]]*/, "", val); gsub(/"/, "", val)
        key = val
      }
      /^[[:space:]]*source_type:/ {
        val = $0; sub(/.*source_type:[[:space:]]*/, "", val); gsub(/"/, "", val)
        st = val
      }
      /^[[:space:]]*source_url:/ {
        val = $0; sub(/.*source_url:[[:space:]]*/, "", val); gsub(/"/, "", val)
        src_url = val
      }
      /^[[:space:]]*content_hash:/ {
        val = $0; sub(/.*content_hash:[[:space:]]*/, "", val); gsub(/"/, "", val)
        chash = val
      }
      /^[[:space:]]*path:/ && !/^[[:space:]]*-/ {
        val = $0; sub(/.*path:[[:space:]]*/, "", val); gsub(/"/, "", val)
        path = val
      }
      END {
        if (key != "" && st == "ingested") {
          printf "%s\t%s\t%s\t%s\t%s\n", key, src_url, chash, path, kind
        }
      }
    ' "$manifest"
  fi
}

# ---------------------------------------------------------------------------
# _gkr_update_entry MANIFEST KEY CONTENT_HASH FETCHED_AT — update a single
# ingested entry's content_hash and fetched_at in the brain-index manifest.
# Atomic via sibling tempfile + validate + rename.
# ---------------------------------------------------------------------------
_gkr_update_entry() {
  local manifest="$1"
  local key="$2"
  local content_hash="$3"
  local fetched_at="$4"

  local tmpfile="${manifest}.tmp.$$.yaml"

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$manifest" "$key" "$content_hash" "$fetched_at" "$tmpfile" <<'PYEOF'
import sys, yaml

manifest_path = sys.argv[1]
key = sys.argv[2]
content_hash = sys.argv[3]
fetched_at = sys.argv[4]
tmpfile = sys.argv[5]

with open(manifest_path) as f:
    doc = yaml.safe_load(f) or {}

for e in (doc.get("entries") or []):
    if e.get("key") == key and e.get("source_type") == "ingested":
        trust = e.get("trust") or {}
        if content_hash:
            trust["content_hash"] = content_hash
        if fetched_at:
            trust["fetched_at"] = fetched_at
        e["trust"] = trust
        break

with open(tmpfile, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PYEOF
  else
    # awk fallback: in-place field replacement.
    cp "$manifest" "$tmpfile"
    if [ -n "$content_hash" ]; then
      # Replace content_hash in the matching entry block.
      # This is a simplified replacement — works when entries have unique hashes.
      sed -i.bak "s/content_hash:.*/content_hash: \"$content_hash\"/" "$tmpfile"
      rm -f "${tmpfile}.bak"
    fi
    if [ -n "$fetched_at" ]; then
      sed -i.bak "s/fetched_at:.*/fetched_at: \"$fetched_at\"/" "$tmpfile"
      rm -f "${tmpfile}.bak"
    fi
  fi

  # Validate before committing.
  local val_rc=0
  env -u _GAIA_PATHS_LOADED bash "$_GKR_VALIDATE" "$tmpfile" || val_rc=$?
  case "$val_rc" in
    0|3)
      mv "$tmpfile" "$manifest"
      ;;
    *)
      printf 'gaia-knowledge-refresh.sh: brain-index validation failed (exit %d); prior manifest preserved\n' "$val_rc" >&2
      rm -f "$tmpfile"
      return 1
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# _gkr_mark_failed INGESTED_FILE — set the ingested file's frontmatter
# status field to "failed". The stale file content is preserved intact.
# The brain-index trust block is NOT modified (its schema has a closed set
# of fields with additionalProperties: false).
# ---------------------------------------------------------------------------
_gkr_mark_failed() {
  local ingested_file="$1"

  if [ ! -f "$ingested_file" ]; then
    printf 'gaia-knowledge-refresh.sh: cannot mark failed — file not found: %s\n' "$ingested_file" >&2
    return 1
  fi

  local tmpfile="${ingested_file}.tmp.$$"

  # Rewrite the frontmatter, flipping status: to "failed", preserve body.
  awk '
    BEGIN { n=0; done=0 }
    /^---[[:space:]]*$/ {
      n++
      print
      if (n == 2) { done=1 }
      next
    }
    n == 1 && !done {
      if ($0 ~ /^status:/) {
        print "status: failed"
        next
      }
      print
      next
    }
    { print }
  ' "$ingested_file" > "$tmpfile"

  mv "$tmpfile" "$ingested_file"
  return 0
}

# ---------------------------------------------------------------------------
# _gkr_overwrite_ingested_file SLUG BODY — atomic overwrite of an existing
# ingested file with new content, preserving provenance frontmatter fields
# that are updated (content_hash, fetched_at, status).
# ---------------------------------------------------------------------------
_gkr_overwrite_ingested_file() {
  local slug="$1"
  local new_body="$2"
  local content_hash="$3"
  local fetched_at="$4"
  local ingested_file="$5"

  local tmpfile="${ingested_file}.tmp.$$"

  # Read the existing frontmatter and update the mutable fields.
  awk -v new_hash="$content_hash" -v new_fetched="$fetched_at" '
    BEGIN { n=0; done=0 }
    /^---[[:space:]]*$/ {
      n++
      if (n == 1) { print; next }
      if (n == 2) { print; done=1; next }
    }
    n == 1 && !done {
      if ($0 ~ /^content_hash:/) {
        printf "content_hash: %s\n", new_hash
        next
      }
      if ($0 ~ /^fetched_at:/) {
        printf "fetched_at: %s\n", new_fetched
        next
      }
      if ($0 ~ /^status:/) {
        print "status: current"
        next
      }
      print
      next
    }
    done { next }
  ' "$ingested_file" > "$tmpfile"

  # Append the new body.
  printf '%s\n' "$new_body" >> "$tmpfile"

  # Atomic rename.
  mv "$tmpfile" "$ingested_file"
}

# ---------------------------------------------------------------------------
# Main entry point: gaia_knowledge_refresh
# ---------------------------------------------------------------------------
gaia_knowledge_refresh() {
  local fetched_content=""

  # Parse arguments.
  while [ $# -gt 0 ]; do
    case "$1" in
      --fetched-content)
        fetched_content="$2"; shift 2 ;;
      *)
        printf 'gaia-knowledge-refresh.sh: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  local manifest="$GAIA_KNOWLEDGE_DIR/brain-index.yaml"
  if [ ! -f "$manifest" ]; then
    printf 'gaia-knowledge-refresh.sh: brain-index.yaml not found at %s\n' "$manifest" >&2
    return 1
  fi

  local project_root="${CLAUDE_PROJECT_ROOT:-$PWD}"

  # Enumerate ingested entries.
  local entries_data
  entries_data="$(_gkr_enumerate_ingested "$manifest")"

  if [ -z "$entries_data" ]; then
    printf 'gaia-knowledge-refresh.sh: no ingested entries found; nothing to refresh\n' >&2
    return 0
  fi

  local skipped=0
  local updated=0
  local failed=0

  # Process each ingested entry.
  while IFS="$(printf '\t')" read -r key source_url stored_hash rel_path kind; do
    [ -n "$key" ] || continue

    printf 'gaia-knowledge-refresh.sh: refreshing: %s\n' "$key" >&2

    # Resolve ingested file path.
    local ingested_file
    case "$rel_path" in
      /*) ingested_file="$rel_path" ;;
      *)  ingested_file="${project_root}/${rel_path}" ;;
    esac

    # Re-fetch the content.
    local new_content=""
    local fetch_ok=1

    if [ -n "$fetched_content" ]; then
      # Test seam: content is provided via --fetched-content.
      if [ -f "$fetched_content" ]; then
        new_content="$(cat "$fetched_content")" || fetch_ok=0
      else
        fetch_ok=0
      fi
    else
      # Production path: re-fetch from source_url.
      # For file sources, re-read from the original path.
      # For URL sources, the orchestration layer must provide --fetched-content.
      case "$kind" in
        file)
          if [ -f "$source_url" ]; then
            new_content="$(cat "$source_url")" || fetch_ok=0
          else
            fetch_ok=0
          fi
          ;;
        *)
          # URL/llms_txt/stdin: require --fetched-content from orchestration.
          printf 'gaia-knowledge-refresh.sh: %s requires --fetched-content for URL sources\n' "$key" >&2
          fetch_ok=0
          ;;
      esac
    fi

    # Handle fetch failure.
    if [ "$fetch_ok" = "0" ] || [ -z "$new_content" ]; then
      printf 'gaia-knowledge-refresh.sh: fetch failed for %s — marking failed, preserving stale file\n' "$key" >&2
      _gkr_mark_failed "$ingested_file" || true
      failed=$((failed + 1))
      continue
    fi

    # Strip HTML (same as feed pipeline).
    local clean_content
    clean_content="$(_gic_strip_html "$new_content" "$kind")"

    # Compute content hash of the re-fetched, post-strip body.
    local new_hash
    new_hash="$(printf '%s\n' "$clean_content" | _gic_sha256_stdin)"

    # Three-way reconcile.
    if [ "$new_hash" = "$stored_hash" ]; then
      # Hash match — SKIP.
      printf 'gaia-knowledge-refresh.sh: %s — hash match, skipping\n' "$key" >&2
      skipped=$((skipped + 1))
    else
      # Content differs — overwrite file + update entry.
      printf 'gaia-knowledge-refresh.sh: %s — content changed, updating\n' "$key" >&2

      local fetched_at
      fetched_at="$(_gic_date_now_iso)"

      # Overwrite the ingested file atomically.
      if [ -f "$ingested_file" ]; then
        _gkr_overwrite_ingested_file "$key" "$clean_content" "$new_hash" "$fetched_at" "$ingested_file"
      fi

      # Update the brain-index entry.
      _gkr_update_entry "$manifest" "$key" "$new_hash" "$fetched_at" || {
        printf 'gaia-knowledge-refresh.sh: failed to update brain-index for %s\n' "$key" >&2
      }

      updated=$((updated + 1))
    fi
  done <<EOF
$entries_data
EOF

  printf 'gaia-knowledge-refresh.sh: refresh complete — skipped: %d, updated: %d, failed: %d\n' \
    "$skipped" "$updated" "$failed" >&2

  return 0
}

# ---------------------------------------------------------------------------
# CLI dispatcher — runs only when executed directly, not when sourced.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  gaia_knowledge_refresh "$@"
  exit $?
fi
