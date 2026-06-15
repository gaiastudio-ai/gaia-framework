#!/usr/bin/env bash
# gaia-feed.sh — one-gesture external-document ingestion into the Brain.
#
# WHAT IT DOES
#   Five-stage pipeline: classify source → fetch → strip HTML → write ingested
#   file with provenance frontmatter → register brain-index entry. Supports four
#   source kinds: url, file, stdin, llms_txt.
#
# USAGE
#   gaia_feed [--slug SLUG] [--tags TAG1,TAG2] [--ttl DAYS]
#             [--kind url|file|llms_txt|stdin]
#             [--fetched-content FILE] <source>
#
#   <source> is a URL, a local file path, or "-" for stdin.
#   --fetched-content is a seam for URL ingestion: the orchestration layer
#   (SKILL.md) fetches via WebFetch and passes the content as a file path.
#   --kind overrides the auto-detected source kind. The orchestration layer
#   passes --kind llms_txt when the llms-full.txt probe succeeds, so the
#   script stamps the correct ingest_source_kind and confidence tier.
#
# SOURCEABLE + EXECUTABLE
#   When sourced, exports gaia_feed() and its _gf_ helper functions.
#   When executed directly, dispatches gaia_feed() with CLI args.
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags. LC_ALL=C. set -euo pipefail.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Source shared helpers
# ---------------------------------------------------------------------------
_gf_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source gaia-paths.sh for GAIA_KNOWLEDGE_DIR etc.
# shellcheck source=../lib/gaia-paths.sh
. "$_gf_self_dir/../lib/gaia-paths.sh" || {
  printf 'gaia-feed.sh: could not source gaia-paths.sh\n' >&2
  return 1 2>/dev/null || exit 1
}

# Sibling validator.
_GF_VALIDATE="$_gf_self_dir/validate-brain-index.sh"

# ---------------------------------------------------------------------------
# Stage helpers (all prefixed _gf_ to avoid namespace collision)
# ---------------------------------------------------------------------------

# _gf_sha256_file FILE — bare hex digest of a file.
_gf_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unknown\n'
  fi
}

# _gf_sha256_stdin — bare hex digest of stdin content.
_gf_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    printf 'unknown\n'
  fi
}

# _gf_slugify STRING — convert a string to a URL-safe slug.
_gf_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//'
}

# _gf_yaml_escape STRING — escape a string for YAML scalar value.
_gf_yaml_escape() {
  local val="$1"
  # If the value contains special characters, wrap in double quotes.
  case "$val" in
    *':'*|*'#'*|*'"'*|*"'"*|*'['*|*']'*|*'{'*|*'}'*|*'&'*|*'*'*|*'!'*|*'|'*|*'>'*|*'%'*|*'@'*|*'`'*)
      # Escape internal double quotes by doubling them.
      val="$(printf '%s' "$val" | sed 's/"/\\"/g')"
      printf '"%s"' "$val"
      ;;
    *)
      printf '%s' "$val"
      ;;
  esac
}

# _gf_date_now_iso — current UTC timestamp in ISO-8601.
_gf_date_now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# _gf_date_add_days DAYS — add N days to now, output ISO-8601.
# Dual idiom: macOS date -v / GNU date -d.
_gf_date_add_days() {
  local days="$1"
  if date -v +1d '+%Y' >/dev/null 2>&1; then
    # macOS / BSD date
    date -u -v "+${days}d" '+%Y-%m-%dT%H:%M:%SZ'
  else
    # GNU date
    date -u -d "+${days} days" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# _gf_extract_title CONTENT — extract the first H1 heading from markdown content.
_gf_extract_title() {
  local title
  title="$(printf '%s' "$1" | grep -m1 '^# ' | sed 's/^# //')"
  if [ -z "$title" ]; then
    # Fallback: first H2
    title="$(printf '%s' "$1" | grep -m1 '^## ' | sed 's/^## //')"
  fi
  printf '%s' "$title"
}

# _gf_token_estimate CONTENT — rough token estimate via word count.
_gf_token_estimate() {
  local words
  words="$(printf '%s' "$1" | wc -w | tr -d ' ')"
  printf '%s' "$words"
}

# ---------------------------------------------------------------------------
# Stage 1: classify source
# ---------------------------------------------------------------------------
_gf_classify_source() {
  local source="$1"
  if [ "$source" = "-" ]; then
    printf 'stdin'
  elif printf '%s' "$source" | grep -qE '^https?://'; then
    printf 'url'
  elif [ -f "$source" ]; then
    printf 'file'
  else
    printf 'unknown'
  fi
}

# ---------------------------------------------------------------------------
# Stage 2: fetch content
# ---------------------------------------------------------------------------
_gf_fetch() {
  local source="$1"
  local kind="$2"
  local fetched_content="${3:-}"

  case "$kind" in
    file)
      cat "$source"
      ;;
    stdin)
      cat
      ;;
    url|llms_txt)
      # URL and llms_txt fetching is orchestrated via SKILL.md WebFetch;
      # the script receives the already-fetched content via --fetched-content.
      if [ -n "$fetched_content" ] && [ -f "$fetched_content" ]; then
        cat "$fetched_content"
      else
        printf 'gaia-feed.sh: %s fetch requires --fetched-content (WebFetch orchestration seam)\n' "$kind" >&2
        return 1
      fi
      ;;
    *)
      printf 'gaia-feed.sh: unknown source kind: %s\n' "$kind" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Stage 3: strip HTML (for URL sources)
# ---------------------------------------------------------------------------
_gf_strip_html() {
  local content="$1"
  local kind="$2"
  if [ "$kind" = "url" ] || [ "$kind" = "llms_txt" ]; then
    # Basic HTML stripping: remove tags, decode common entities.
    printf '%s' "$content" \
      | sed 's/<[^>]*>//g' \
      | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&nbsp;/ /g'
  else
    printf '%s' "$content"
  fi
}

# ---------------------------------------------------------------------------
# Guard seams
# ---------------------------------------------------------------------------

# _gf_safe_fetch_guard — pass-through placeholder; hardened downstream.
_gf_safe_fetch_guard() {
  return 0
}

# _gf_slug_containment_guard — reject path separators and traversal in slugs.
_gf_slug_containment_guard() {
  local slug="$1"
  case "$slug" in
    *'/'*|*'..'*)
      printf 'gaia-feed.sh: slug containment violation — path separator or traversal in slug: %s\n' "$slug" >&2
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Stage 4: infer metadata
# ---------------------------------------------------------------------------
_gf_infer_metadata() {
  local content="$1"
  local source="$2"
  local kind="$3"
  local slug_override="${4:-}"

  local title
  title="$(_gf_extract_title "$content")"

  local slug
  if [ -n "$slug_override" ]; then
    slug="$slug_override"
  elif [ -n "$title" ]; then
    slug="$(_gf_slugify "$title")"
  elif [ "$kind" = "file" ]; then
    # Derive from filename.
    local basename_no_ext
    basename_no_ext="$(basename "$source" .md)"
    slug="$(_gf_slugify "$basename_no_ext")"
  else
    slug="ingested-$(date -u '+%s')"
  fi

  if [ -z "$title" ]; then
    if [ "$kind" = "file" ]; then
      title="$(basename "$source" .md)"
    else
      title="$slug"
    fi
  fi

  # Tags: derive from source kind + any content signals.
  local tags="ingested,$kind"

  printf '%s\t%s\t%s' "$title" "$slug" "$tags"
}

# ---------------------------------------------------------------------------
# Stage 5: compute provenance (exactly 11 fields)
# ---------------------------------------------------------------------------

# _gf_confidence_for_kind KIND — tiered confidence by source kind.
_gf_confidence_for_kind() {
  case "$1" in
    llms_txt) printf '0.9' ;;
    file)     printf '0.8' ;;
    url)      printf '0.7' ;;
    stdin)    printf '0.8' ;;
    *)        printf '0.7' ;;
  esac
}

# _gf_emit_frontmatter — write the 11-field provenance frontmatter to stdout.
_gf_emit_frontmatter() {
  local title="$1"
  local slug="$2"
  local kind="$3"
  local source_url="$4"
  local content_hash="$5"
  local tags="$6"
  local token_estimate="$7"
  local ttl_days="$8"
  local fetched_at="$9"
  local expires_at="${10}"

  cat <<EOF
---
title: $(_gf_yaml_escape "$title")
slug: $slug
ingest_source_kind: $kind
source_url: ${source_url:-null}
fetched_at: $fetched_at
expires_at: $expires_at
content_hash: $content_hash
ttl_days: $ttl_days
token_estimate: $token_estimate
tags: [$tags]
status: current
---
EOF
}

# ---------------------------------------------------------------------------
# Write ingested file (atomic sibling tempfile + mv)
# ---------------------------------------------------------------------------
_gf_write_ingested_file() {
  local slug="$1"
  local frontmatter="$2"
  local body="$3"

  local ingested_dir="$GAIA_KNOWLEDGE_DIR/ingested"
  mkdir -p "$ingested_dir"

  local target="$ingested_dir/${slug}.md"
  local tmpfile="${target}.tmp.$$"

  # Write frontmatter then body. Command substitution strips the trailing
  # newline from the heredoc, so we re-add it with %s\n. The body gets its
  # own trailing newline to ensure the file ends cleanly.
  printf '%s\n' "$frontmatter" > "$tmpfile"
  printf '%s\n' "$body" >> "$tmpfile"

  # Atomic rename.
  mv "$tmpfile" "$target"
  printf '%s\n' "$target"
}

# ---------------------------------------------------------------------------
# Register brain-index entry (append/replace ingested entry; atomic write)
# ---------------------------------------------------------------------------
_gf_register_brain_index() {
  local slug="$1"
  local path="$2"
  local tags="$3"
  local content_hash="$4"
  local source_url="$5"
  local fetched_at="$6"
  local expires_at="$7"
  local confidence="$8"
  local title="$9"

  local manifest="$GAIA_KNOWLEDGE_DIR/brain-index.yaml"

  if [ ! -f "$manifest" ]; then
    printf 'gaia-feed.sh: brain-index.yaml not found at %s\n' "$manifest" >&2
    return 1
  fi

  # Make path relative to project root. Use the canonicalized project root
  # from gaia-paths.sh to handle macOS /var vs /private/var symlink mismatch.
  local project_root_canon="${_GAIA_ROOT_CANON:-${CLAUDE_PROJECT_ROOT:-$PWD}}"
  local rel_path
  # Canonicalize the incoming path so the prefix strip works regardless of
  # symlink differences (e.g. /var/... vs /private/var/... on macOS).
  local abs_path
  if [ -f "$path" ]; then
    abs_path="$(_gaia_paths_canonicalize "$path")"
  else
    abs_path="$path"
  fi
  case "$abs_path" in
    "${project_root_canon}/"*)
      rel_path="${abs_path#"${project_root_canon}/"}"
      ;;
    *)
      rel_path="$abs_path"
      ;;
  esac

  # Build the new entry YAML.
  local synopsis="Ingested document: ${title}"
  local tag_list
  tag_list="$(printf '%s' "$tags" | sed 's/,/", "/g')"

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

  # Build the new manifest: remove any existing entry with this key, then append.
  # The validator dispatches on file extension — only .yaml/.yml/.json/.md are
  # recognized. Give the staging file a .yaml suffix (same pattern as the reindex
  # sweep) so validation works on hosts WITH a JSON-schema backend (CI).
  local tmpfile="${manifest}.tmp.$$.yaml"

  # Use python3+PyYAML if available for safe YAML manipulation; fall back to
  # awk-based append for portability.
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
    # Fallback: awk-based append for environments without python3+PyYAML.
    # Copy existing manifest without the trailing empty line, append entry.
    cp "$manifest" "$tmpfile"
    # If entries is empty array [], replace it.
    if grep -q '^entries: \[\]' "$tmpfile"; then
      sed -i.bak 's/^entries: \[\]/entries:/' "$tmpfile"
      rm -f "${tmpfile}.bak"
    fi
    printf '%s\n' "$entry" >> "$tmpfile"
  fi

  # Validate the tempfile BEFORE renaming into place.
  # Unset _GAIA_PATHS_LOADED so the validator's subprocess re-sources
  # gaia-paths.sh fresh (it's exported by the parent and the idempotent
  # guard would otherwise skip the load, leaving functions undefined).
  local val_rc=0
  env -u _GAIA_PATHS_LOADED bash "$_GF_VALIDATE" "$tmpfile" || val_rc=$?
  case "$val_rc" in
    0|3)
      # 0=valid, 3=schema backend unavailable (structural check skipped).
      mv "$tmpfile" "$manifest"
      ;;
    *)
      printf 'gaia-feed.sh: brain-index validation failed (exit %d); prior manifest preserved\n' "$val_rc" >&2
      rm -f "$tmpfile"
      return 1
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# Main entry point: gaia_feed
# ---------------------------------------------------------------------------
gaia_feed() {
  local slug_override=""
  local tags_override=""
  local kind_override=""
  local ttl_days="30"
  local fetched_content=""
  local source=""

  # Parse arguments.
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug)
        slug_override="$2"; shift 2 ;;
      --tags)
        tags_override="$2"; shift 2 ;;
      --ttl)
        ttl_days="$2"; shift 2 ;;
      --kind)
        kind_override="$2"; shift 2 ;;
      --fetched-content)
        fetched_content="$2"; shift 2 ;;
      -*)
        if [ "$1" = "-" ]; then
          source="-"; shift
        else
          printf 'gaia-feed.sh: unknown option: %s\n' "$1" >&2
          return 1
        fi
        ;;
      *)
        source="$1"; shift ;;
    esac
  done

  if [ -z "$source" ]; then
    printf 'gaia-feed.sh: usage: gaia_feed [--slug SLUG] [--tags TAGS] [--ttl DAYS] [--kind KIND] <source>\n' >&2
    return 1
  fi

  # Stage 1: classify source.
  local kind
  if [ -n "$kind_override" ]; then
    # Validate --kind against the 4-value closed enum.
    case "$kind_override" in
      url|file|llms_txt|stdin) kind="$kind_override" ;;
      *)
        printf 'gaia-feed.sh: invalid --kind value: %s (must be url|file|llms_txt|stdin)\n' "$kind_override" >&2
        return 1
        ;;
    esac
  else
    kind="$(_gf_classify_source "$source")"
  fi
  printf 'gaia-feed.sh: source kind: %s\n' "$kind" >&2

  if [ "$kind" = "unknown" ]; then
    printf 'gaia-feed.sh: cannot classify source: %s\n' "$source" >&2
    return 1
  fi

  # Safe-fetch guard (pass-through in V1).
  _gf_safe_fetch_guard "$source" || return $?

  # Stage 2: fetch content.
  local content
  content="$(_gf_fetch "$source" "$kind" "$fetched_content")"

  if [ -z "$content" ]; then
    printf 'gaia-feed.sh: empty content from source: %s\n' "$source" >&2
    return 1
  fi

  # Stage 3: strip HTML.
  local clean_content
  clean_content="$(_gf_strip_html "$content" "$kind")"

  # Stage 4: infer metadata.
  local meta
  meta="$(_gf_infer_metadata "$clean_content" "$source" "$kind" "$slug_override")"
  local title slug tags
  title="$(printf '%s' "$meta" | cut -f1)"
  slug="$(printf '%s' "$meta" | cut -f2)"
  tags="$(printf '%s' "$meta" | cut -f3)"

  if [ -n "$tags_override" ]; then
    tags="$tags_override"
  fi

  # Slug containment guard.
  _gf_slug_containment_guard "$slug" || return $?

  printf 'gaia-feed.sh: slug: %s\n' "$slug" >&2
  printf 'gaia-feed.sh: title: %s\n' "$title" >&2

  # Compute content hash of the clean body.
  local content_hash
  content_hash="$(printf '%s\n' "$clean_content" | _gf_sha256_stdin)"

  # Token estimate.
  local token_estimate
  token_estimate="$(_gf_token_estimate "$clean_content")"

  # Source URL: for url/llms_txt the original URL; for file the path; stdin null.
  local source_url
  case "$kind" in
    url|llms_txt) source_url="$source" ;;
    file)         source_url="$source" ;;
    stdin)        source_url="null" ;;
    *)            source_url="null" ;;
  esac

  # Stage 5: compute provenance and write.
  local fetched_at expires_at confidence
  fetched_at="$(_gf_date_now_iso)"
  expires_at="$(_gf_date_add_days "$ttl_days")"
  confidence="$(_gf_confidence_for_kind "$kind")"

  local frontmatter
  frontmatter="$(_gf_emit_frontmatter "$title" "$slug" "$kind" "$source_url" \
    "$content_hash" "$tags" "$token_estimate" "$ttl_days" "$fetched_at" "$expires_at")"

  # Write ingested file (atomic).
  local ingested_path
  ingested_path="$(_gf_write_ingested_file "$slug" "$frontmatter" "$clean_content")"
  printf 'gaia-feed.sh: wrote: %s\n' "$ingested_path" >&2

  # Register brain-index entry (atomic, validated).
  _gf_register_brain_index "$slug" "$ingested_path" "$tags" "$content_hash" \
    "$source_url" "$fetched_at" "$expires_at" "$confidence" "$title" \
    || return $?

  printf 'gaia-feed.sh: ingestion complete for: %s\n' "$slug" >&2
  return 0
}

# ---------------------------------------------------------------------------
# CLI dispatcher — runs only when executed directly, not when sourced.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  gaia_feed "$@"
  exit $?
fi
