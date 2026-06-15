#!/usr/bin/env bash
# ingest-common.sh — shared fetch, strip, hash, and metadata helpers for the
# Brain's ingestion pipeline. Both the feed writer and the refresh lifecycle
# source this library so their implementations never drift.
#
# SOURCEABLE ONLY — never execute directly.
#
# Exports (all prefixed _gic_ to avoid namespace collision):
#   _gic_sha256_file FILE          — bare hex digest of a file
#   _gic_sha256_stdin              — bare hex digest of stdin
#   _gic_slugify STRING            — URL-safe slug
#   _gic_sanitize_slug STRING      — sanitise + enforce slug safety
#   _gic_yaml_escape STRING        — escape for YAML scalar
#   _gic_date_now_iso              — current UTC ISO-8601 timestamp
#   _gic_date_add_days DAYS        — add N days, output ISO-8601
#   _gic_classify_source SOURCE    — url|file|stdin|unknown
#   _gic_fetch SOURCE KIND [FETCHED_CONTENT]
#   _gic_strip_html CONTENT KIND
#   _gic_strip_source_frontmatter CONTENT — remove any pre-existing frontmatter
#   _gic_wrap_content_boundary CONTENT    — wrap with ingestion boundary markers
#   _gic_extract_title CONTENT
#   _gic_token_estimate CONTENT
#   _gic_confidence_for_kind KIND
#   _gic_safe_fetch_guard SOURCE   — SSRF + scheme check (real implementation)
#   _gic_check_size_cap FILE       — reject if file exceeds 10 MB
#   _gic_slug_containment_guard SLUG INGESTED_DIR — realpath containment
#   _gic_enforce_file_mode FILE    — set 0644 permissions
#
# Portability: bash 3.2 (macOS default) clean. LC_ALL=C.

# Idempotent source guard.
if [ "${_GIC_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# Source the safe-fetch guard library (SSRF blocklist, scheme restriction,
# size cap, timeout enforcement).
_gic_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=safe-fetch-guard.sh
. "$_gic_self_dir/safe-fetch-guard.sh" || {
  printf 'ingest-common.sh: could not source safe-fetch-guard.sh\n' >&2
  return 1 2>/dev/null || true
}

# --- hash helpers ---

_gic_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unknown\n'
  fi
}

_gic_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    printf 'unknown\n'
  fi
}

# --- string helpers ---

_gic_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//'
}

_gic_yaml_escape() {
  local val="$1"
  case "$val" in
    *':'*|*'#'*|*'"'*|*"'"*|*'['*|*']'*|*'{'*|*'}'*|*'&'*|*'*'*|*'!'*|*'|'*|*'>'*|*'%'*|*'@'*|*'`'*)
      val="$(printf '%s' "$val" | sed 's/"/\\"/g')"
      printf '"%s"' "$val"
      ;;
    *)
      printf '%s' "$val"
      ;;
  esac
}

# --- date helpers ---

_gic_date_now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_gic_date_add_days() {
  local days="$1"
  if date -v +1d '+%Y' >/dev/null 2>&1; then
    date -u -v "+${days}d" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "+${days} days" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# --- classification ---

_gic_classify_source() {
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

# --- fetch ---

_gic_fetch() {
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
      if [ -n "$fetched_content" ] && [ -f "$fetched_content" ]; then
        cat "$fetched_content"
      else
        printf 'ingest-common.sh: %s fetch requires --fetched-content (WebFetch orchestration seam)\n' "$kind" >&2
        return 1
      fi
      ;;
    *)
      printf 'ingest-common.sh: unknown source kind: %s\n' "$kind" >&2
      return 1
      ;;
  esac
}

# --- HTML strip ---

_gic_strip_html() {
  local content="$1"
  local kind="$2"
  if [ "$kind" = "url" ] || [ "$kind" = "llms_txt" ]; then
    printf '%s' "$content" \
      | sed 's/<[^>]*>//g' \
      | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&nbsp;/ /g'
  else
    printf '%s' "$content"
  fi
}

# --- metadata ---

_gic_extract_title() {
  local title
  title="$(printf '%s' "$1" | grep -m1 '^# ' | sed 's/^# //')"
  if [ -z "$title" ]; then
    title="$(printf '%s' "$1" | grep -m1 '^## ' | sed 's/^## //')"
  fi
  printf '%s' "$title"
}

_gic_token_estimate() {
  local words
  words="$(printf '%s' "$1" | wc -w | tr -d ' ')"
  printf '%s' "$words"
}

_gic_confidence_for_kind() {
  case "$1" in
    llms_txt) printf '0.9' ;;
    file)     printf '0.8' ;;
    url)      printf '0.7' ;;
    stdin)    printf '0.8' ;;
    *)        printf '0.7' ;;
  esac
}

# --- content sanitisation helpers ---

# _gic_strip_source_frontmatter CONTENT — strip any pre-existing YAML
# frontmatter from fetched content so ingested HTML/markdown cannot carry
# prompt-injection via inherited frontmatter fields. The ingestion pipeline
# generates its own provenance frontmatter; nothing from the source leaks.
_gic_strip_source_frontmatter() {
  local content="$1"
  printf '%s' "$content" | awk '
    BEGIN { n=0; skip=0 }
    /^---[[:space:]]*$/ {
      n++
      if (n == 1) { skip=1; next }
      if (n == 2) { skip=0; next }
    }
    !skip { print }
  '
}

# _gic_wrap_content_boundary CONTENT — wrap content with ingestion boundary
# markers. These markers delimit the ingested content so downstream consumers
# can distinguish it from generated metadata. They also serve as a content
# isolation boundary that prevents ingested text from being interpreted as
# framework directives.
_gic_wrap_content_boundary() {
  local content="$1"
  printf '<!-- INGESTED_CONTENT_BEGIN -->\n%s\n<!-- INGESTED_CONTENT_END -->\n' "$content"
}

# --- slug sanitisation ---

# _gic_sanitize_slug STRING — produce a safe slug from an arbitrary input.
# Strips path separators, traversal sequences, and non-alphanumeric characters,
# then normalises to lowercase with hyphens. Returns the sanitised slug on
# stdout. Falls back to a timestamp slug if the input sanitises to empty.
_gic_sanitize_slug() {
  local raw="$1"
  # Strip path components: remove everything before the last path separator.
  local base
  base="$(basename -- "$raw" 2>/dev/null || printf '%s' "$raw")"
  # Remove traversal sequences.
  base="$(printf '%s' "$base" | sed 's/\.\.//g')"
  # Slugify: lowercase, replace non-alnum with hyphens, collapse, trim.
  local slug
  slug="$(printf '%s' "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//')"
  if [ -z "$slug" ]; then
    slug="ingested-$(date -u '+%s')"
  fi
  printf '%s' "$slug"
}

# --- guard implementations ---

# _gic_safe_fetch_guard SOURCE — SSRF mitigation + scheme restriction.
# For URL sources: checks the scheme (http/https only) and resolves the
# host to verify it does not point to a private/link-local/loopback/
# cloud-metadata address. Non-URL sources pass through.
# Deterministic, testable, cannot be bypassed by prompt drift.
_gic_safe_fetch_guard() {
  local source="$1"

  # Scheme restriction.
  _sfg_check_scheme "$source" || return $?

  # SSRF blocklist check (DNS resolution + IP range check).
  _sfg_check_ssrf "$source" || return $?

  return 0
}

# _gic_check_size_cap FILE — reject if the file exceeds the 10 MB cap.
# Delegates to the safe-fetch guard library.
_gic_check_size_cap() {
  _sfg_check_size_cap "$@"
}

# _gic_slug_containment_guard SLUG [INGESTED_DIR] — hardened slug
# containment with realpath verification.
#
# Two-layer defence:
#   1. Character-level: reject slugs with path separators or traversal sequences.
#   2. Realpath: resolve the would-be write path and assert it is a
#      prefix-child of the canonicalised ingested/ root directory.
#
# The INGESTED_DIR parameter is optional; it defaults to
# $GAIA_KNOWLEDGE_DIR/ingested if not provided.
_gic_slug_containment_guard() {
  local slug="$1"
  local ingested_dir="${2:-${GAIA_KNOWLEDGE_DIR:-}/ingested}"

  # Layer 1: character-level rejection.
  case "$slug" in
    *'/'*|*'..'*)
      printf 'ingest-common.sh: slug containment violation — path separator or traversal in slug: %s\n' "$slug" >&2
      return 1
      ;;
  esac

  # Layer 2: realpath containment check.
  # Resolve the ingested directory to its canonical form.
  if [ -d "$ingested_dir" ]; then
    local canon_root
    canon_root="$(cd "$ingested_dir" 2>/dev/null && pwd -P)"

    # Construct the would-be write path and resolve it.
    local target_path="${ingested_dir}/${slug}.md"
    local canon_target

    # For realpath: resolve the directory portion, then append the filename.
    local target_dir
    target_dir="$(dirname -- "$target_path")"
    if [ -d "$target_dir" ]; then
      canon_target="$(cd "$target_dir" 2>/dev/null && pwd -P)/$(basename -- "$target_path")"
    else
      # Target directory doesn't exist — use literal concatenation.
      canon_target="${canon_root}/${slug}.md"
    fi

    # Assert the resolved target is a prefix-child of the ingested root.
    case "$canon_target" in
      "${canon_root}/"*)
        # Good — the file stays under the ingested directory.
        ;;
      *)
        printf 'ingest-common.sh: slug containment violation — resolved path escapes ingested root\n' >&2
        printf '  ingested root: %s\n' "$canon_root" >&2
        printf '  resolved path: %s\n' "$canon_target" >&2
        return 1
        ;;
    esac
  fi

  return 0
}

# _gic_enforce_file_mode FILE — set the file permissions to 0644.
# Ingested files are read-only-except-by-owner as a defense-in-depth measure.
_gic_enforce_file_mode() {
  local file="$1"
  if [ -f "$file" ]; then
    chmod 644 "$file"
  fi
}

_GIC_LOADED=1
export _GIC_LOADED

return 0 2>/dev/null || true
