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
#   _gic_yaml_escape STRING        — escape for YAML scalar
#   _gic_date_now_iso              — current UTC ISO-8601 timestamp
#   _gic_date_add_days DAYS        — add N days, output ISO-8601
#   _gic_classify_source SOURCE    — url|file|stdin|unknown
#   _gic_fetch SOURCE KIND [FETCHED_CONTENT]
#   _gic_strip_html CONTENT KIND
#   _gic_extract_title CONTENT
#   _gic_token_estimate CONTENT
#   _gic_confidence_for_kind KIND
#   _gic_safe_fetch_guard SOURCE
#   _gic_slug_containment_guard SLUG
#
# Portability: bash 3.2 (macOS default) clean. LC_ALL=C.

# Idempotent source guard.
if [ "${_GIC_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi

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

# --- guard seams ---

_gic_safe_fetch_guard() {
  return 0
}

_gic_slug_containment_guard() {
  local slug="$1"
  case "$slug" in
    *'/'*|*'..'*)
      printf 'ingest-common.sh: slug containment violation — path separator or traversal in slug: %s\n' "$slug" >&2
      return 1
      ;;
  esac
  return 0
}

_GIC_LOADED=1
export _GIC_LOADED

return 0 2>/dev/null || true
