#!/usr/bin/env bash
# capture-screenshot.sh — capture a screenshot of a URL at a given breakpoint.
# Contract stub with _main guard.
#
# Usage:
#   capture-screenshot.sh --url <url> --breakpoint <width> --output <path>
#
# Exit codes:
#   0 — screenshot captured successfully
#   1 — usage error
#   2 — no headless browser available (caller degrades to UNVERIFIED)

set -euo pipefail

SCRIPT_NAME="capture-screenshot.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- Public function ----------

capture_screenshot() {
  local url="${1:?usage: capture_screenshot <url> <breakpoint> <output>}"
  local breakpoint="${2:?usage: capture_screenshot <url> <breakpoint> <output>}"
  local output="${3:?usage: capture_screenshot <url> <breakpoint> <output>}"

  # Probe for a headless browser
  local browser=""
  if command -v chromium >/dev/null 2>&1; then
    browser="chromium"
  elif command -v google-chrome >/dev/null 2>&1; then
    browser="google-chrome"
  elif command -v chromium-browser >/dev/null 2>&1; then
    browser="chromium-browser"
  fi

  if [ -z "$browser" ]; then
    log "no headless browser found (chromium, google-chrome, chromium-browser)"
    log "install Chromium or Google Chrome for screenshot capture"
    return 2
  fi

  # Capture screenshot via headless browser
  local output_dir
  output_dir="$(dirname "$output")"
  mkdir -p "$output_dir"

  "$browser" --headless --disable-gpu --no-sandbox \
    --window-size="${breakpoint},900" \
    --screenshot="$output" \
    "$url" 2>/dev/null

  if [ ! -f "$output" ]; then
    log "screenshot capture failed for $url at ${breakpoint}px"
    return 1
  fi

  log "captured ${breakpoint}px screenshot: $output"
}

# ---------- _main guard ----------

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  URL=""
  BREAKPOINT=""
  OUTPUT=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --url)        [ $# -ge 2 ] || die "flag --url requires a value"; URL="$2"; shift 2 ;;
      --breakpoint) [ $# -ge 2 ] || die "flag --breakpoint requires a value"; BREAKPOINT="$2"; shift 2 ;;
      --output)     [ $# -ge 2 ] || die "flag --output requires a path"; OUTPUT="$2"; shift 2 ;;
      *)            die "unknown argument: $1" ;;
    esac
  done

  [ -n "$URL" ]        || die "usage: --url is required"
  [ -n "$BREAKPOINT" ] || die "usage: --breakpoint is required"
  [ -n "$OUTPUT" ]     || die "usage: --output is required"

  capture_screenshot "$URL" "$BREAKPOINT" "$OUTPUT"
fi
