#!/usr/bin/env bash
# surface-adapter.sh — resolve whether a manual-test surface is configured
#
# Surface-to-config map:
#   browser  → platform "web" in project-config platforms list
#   api      → platform "server" in project-config platforms list
#   mobile   → platform "ios" OR "android" in project-config platforms list
#   desktop  → sprint_review.desktop_commands present and non-empty
#
# Usage:
#   surface-adapter.sh --surface <browser|api|mobile|desktop> \
#                      [--config <path-to-project-config.yaml>]
#
# Exit codes:
#   0 — CONFIGURED (surface is active; proceed with dispatch)
#   2 — SKIPPED (surface not configured; dormant)
#   1 — error (usage, unknown surface, config read failure)
#
# POSIX-ish discipline: bash 3.2 compatible, no [[ ]], no associative arrays.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="surface-adapter.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

skip_surface() {
  printf 'SKIPPED: %s surface not configured\n' "$1"
  exit 2
}

# ---------- Argument parsing ----------
SURFACE=""
CONFIG_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --surface)  [ $# -ge 2 ] || die "flag --surface requires a value"; SURFACE="$2"; shift 2 ;;
    --config)   [ $# -ge 2 ] || die "flag --config requires a path"; CONFIG_PATH="$2"; shift 2 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

[ -n "$SURFACE" ] || die "usage: $SCRIPT_NAME --surface <browser|api|mobile|desktop> [--config <path>]"

# ---------- Config resolution ----------
# If --config not given, try CLAUDE_PROJECT_ROOT and PWD fallbacks.
if [ -z "$CONFIG_PATH" ]; then
  for root in "${CLAUDE_PROJECT_ROOT:-}" "${GAIA_PROJECT_ROOT:-}" "$PWD"; do
    [ -n "$root" ] || continue
    for subpath in ".gaia/config/project-config.yaml" "config/project-config.yaml"; do
      if [ -f "$root/$subpath" ]; then
        CONFIG_PATH="$root/$subpath"
        break 2
      fi
    done
  done
fi

[ -n "$CONFIG_PATH" ] || die "no project-config.yaml found"
[ -f "$CONFIG_PATH" ] || die "config file not found: $CONFIG_PATH"

# ---------- Read platforms from config ----------
# Pure-awk extraction: reads the platforms: line and parses the inline
# YAML list. Handles both flow-style [web, server, ios] and
# block-style (one per line). Bash 3.2 compatible.
read_platforms() {
  awk '
  /^platforms:/ {
    # Flow style: platforms: [web, server, ios]
    if (match($0, /\[.*\]/)) {
      inner = substr($0, RSTART+1, RLENGTH-2)
      gsub(/[ \t]/, "", inner)
      print inner
      next
    }
    # Block style: lines starting with "- "
    while ((getline line) > 0) {
      if (line !~ /^[[:space:]]*-/) break
      gsub(/^[[:space:]]*-[[:space:]]*/, "", line)
      # Strip an inline "# comment" before the trailing-whitespace strip, so an
      # annotated entry like "- server   # functional smoke target" yields the
      # bare platform name ("server") rather than the literal commented string
      # (which would fail the exact comma-delimited match downstream and
      # silently disable the surface).
      gsub(/[[:space:]]*#.*/, "", line)
      gsub(/[[:space:]]*$/, "", line)
      # A list line that is only a comment (e.g. "-   # note") or otherwise
      # empty after stripping must NOT become a bogus empty platform (which
      # would produce a malformed "web,,server" join). Skip empties.
      if (length(line) == 0) continue
      if (length(result) > 0) result = result "," line
      else result = line
    }
    if (length(result) > 0) print result
  }
  ' "$CONFIG_PATH" 2>/dev/null || true
}

# ---------- Check desktop_commands presence ----------
has_desktop_commands() {
  # Look for sprint_review.desktop_commands with at least one child key.
  # Returns 0 (true) if present, 1 (false) if absent/empty.
  awk '
  BEGIN { in_sr=0; in_dc=0; found=0 }
  /^sprint_review:/ { in_sr=1; next }
  in_sr && /^[^ ]/ { in_sr=0 }
  in_sr && /^[[:space:]]+desktop_commands:/ {
    # Check for inline empty: desktop_commands: {}
    if ($0 ~ /\{\}[[:space:]]*$/) { exit 1 }
    in_dc=1; next
  }
  in_dc && /^[[:space:]]{4,}[a-zA-Z_]/ { found=1; exit 0 }
  in_dc && /^[[:space:]]*[a-zA-Z]/ && !/^[[:space:]]{4}/ { exit 1 }
  END { if (found) exit 0; else exit 1 }
  ' "$CONFIG_PATH" 2>/dev/null
}

# ---------- Platform presence check ----------
platform_configured() {
  local target="$1"
  local platforms
  platforms="$(read_platforms)"
  # Check if target appears in the comma-separated list
  echo ",$platforms," | grep -qi ",$target,"
}

# ---------- Surface dispatch ----------
case "$SURFACE" in
  browser)
    if platform_configured "web"; then
      printf 'CONFIGURED: browser surface (platform: web)\n'
      exit 0
    else
      skip_surface "browser"
    fi
    ;;
  api)
    if platform_configured "server"; then
      printf 'CONFIGURED: api surface (platform: server)\n'
      exit 0
    else
      skip_surface "api"
    fi
    ;;
  mobile)
    if platform_configured "ios" || platform_configured "android"; then
      printf 'CONFIGURED: mobile surface\n'
      exit 0
    else
      skip_surface "mobile"
    fi
    ;;
  desktop)
    if has_desktop_commands; then
      printf 'CONFIGURED: desktop surface (sprint_review.desktop_commands)\n'
      exit 0
    else
      skip_surface "desktop"
    fi
    ;;
  *)
    die "unknown surface: $SURFACE (valid: browser, api, mobile, desktop)"
    ;;
esac
