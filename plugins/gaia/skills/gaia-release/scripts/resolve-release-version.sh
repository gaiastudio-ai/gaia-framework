#!/usr/bin/env bash
# resolve-release-version.sh — Strategy-aware release-version resolver.
#
# Reads `release.strategy` from project-config.yaml and dispatches to the
# appropriate version-derivation method:
#
#   conventional-commits  — classify commits since the last v* tag via
#                           classify-commits.js and emit the highest bump level.
#   manual                — signal the caller to prompt for a version.
#   calendar              — derive CalVer (YYYY.MM.PATCH) from today's date.
#
# When release.strategy is absent, defaults to manual (zero regression).
#
# Output (machine-readable, one key=value per line):
#   strategy=<conventional-commits|manual|calendar>
#   bump=<major|minor|patch|none>         (conventional-commits only)
#   version=<YYYY.MM.PATCH>               (calendar only)
#   message=<human-readable note>         (when bump=none)
#
# Exit codes:
#   0 — success (including bump=none, which is a clean "nothing to release")
#   1 — usage / argument error
#   2 — config error
#
# Usage:
#   resolve-release-version.sh --config <path> --project-root <path>

set -euo pipefail

# Source the shared file-to-stack resolution library (for locate_repo_script).
_RRV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/lib/resolve-file-to-stack.sh
. "$_RRV_DIR/../../../scripts/lib/resolve-file-to-stack.sh"

# ---------------------------------------------------------------------------
# Internal helpers (prefixed with _ to satisfy NFR-052 naming convention)
# ---------------------------------------------------------------------------

_log_err() { printf 'resolve-release-version: %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

_parse_args() {
  CONFIG_PATH=""
  PROJECT_ROOT=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --config)    CONFIG_PATH="$2"; shift 2 ;;
      --project-root) PROJECT_ROOT="$2"; shift 2 ;;
      --help|-h)
        printf 'Usage: resolve-release-version.sh --config <path> --project-root <path>\n'
        exit 0
        ;;
      *)
        _log_err "unknown argument: $1"
        exit 1
        ;;
    esac
  done

  if [ -z "$CONFIG_PATH" ]; then
    _log_err "--config <path> is required"
    exit 1
  fi
  if [ -z "$PROJECT_ROOT" ]; then
    _log_err "--project-root <path> is required"
    exit 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    _log_err "config file not found: $CONFIG_PATH"
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Config parsing — minimal YAML reader for release.strategy
# ---------------------------------------------------------------------------

_read_strategy() {
  local config_file="$1"
  local in_release=false
  local strategy=""

  while IFS= read -r line; do
    local trimmed="${line#"${line%%[![:space:]]*}"}"

    # Skip empty lines and comments.
    [ -z "$trimmed" ] && continue
    [[ "$trimmed" == \#* ]] && continue

    # Detect top-level release: block.
    if [[ "$line" =~ ^release[[:space:]]*: ]]; then
      in_release=true
      continue
    fi

    # If we hit another top-level key, leave the release block.
    if $in_release && [[ "$line" =~ ^[a-zA-Z_] ]]; then
      in_release=false
      continue
    fi

    # Inside release block, look for strategy key.
    if $in_release && [[ "$trimmed" =~ ^strategy[[:space:]]*:[[:space:]]*(.*) ]]; then
      strategy="${BASH_REMATCH[1]}"
      # Strip quotes and trailing whitespace.
      strategy="${strategy%\"}"
      strategy="${strategy#\"}"
      strategy="${strategy%\'}"
      strategy="${strategy#\'}"
      strategy="${strategy%"${strategy##*[![:space:]]}"}"
      break
    fi
  done < "$config_file"

  printf '%s' "$strategy"
}

# ---------------------------------------------------------------------------
# Strategy: conventional-commits
# ---------------------------------------------------------------------------

_resolve_conventional_commits() {
  local project_root="$1"

  # Locate classify-commits.js. Discovery order:
  #   1. CLASSIFY_COMMITS_JS env var (explicit override for tests / CI).
  #   2. Shared locate_repo_script helper (walks up from lib dir and
  #      CLAUDE_PLUGIN_ROOT, then CWD — no brittle relative traversal).
  local classify_js="${CLASSIFY_COMMITS_JS:-}"
  if [ -z "$classify_js" ]; then
    classify_js="$(locate_repo_script "classify-commits.js")"
  fi

  if [ -z "$classify_js" ] || [ ! -f "$classify_js" ]; then
    _log_err "classify-commits.js not found (searched from $project_root)"
    exit 2
  fi

  # Determine the anchor (last v* tag, or root commit for first release).
  local anchor
  anchor="$(cd "$project_root" && git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  if [ -z "$anchor" ]; then
    anchor="$(cd "$project_root" && git rev-list --max-parents=0 HEAD 2>/dev/null || true)"
  fi

  if [ -z "$anchor" ]; then
    _log_err "no git history found in $project_root"
    exit 2
  fi

  # Collect commits in the range using the ---COMMIT--- delimiter encoding
  # that classify-commits.js expects for --stdin mode.
  local commit_blob
  commit_blob="$(cd "$project_root" && git log --format='%B---COMMIT---' "${anchor}..HEAD" 2>/dev/null || true)"

  if [ -z "$commit_blob" ]; then
    printf 'strategy=conventional-commits\n'
    printf 'bump=none\n'
    printf 'message=no releasable changes\n'
    return 0
  fi

  # Encode newlines as literal \n for classify-commits.js input contract.
  local encoded
  encoded="$(printf '%s' "$commit_blob" | sed 's/$/\\n/' | tr -d '\n')"

  # Pipe to classify-commits.js via --stdin.
  local classify_output
  classify_output="$(printf '%s' "$encoded" | node "$classify_js" --stdin 2>/dev/null)"

  local bump_size
  bump_size="$(printf '%s' "$classify_output" | grep '^bump_size=' | head -1 | cut -d= -f2)"

  printf 'strategy=conventional-commits\n'
  if [ "$bump_size" = "none" ] || [ -z "$bump_size" ]; then
    printf 'bump=none\n'
    printf 'message=no releasable changes\n'
  else
    printf 'bump=%s\n' "$bump_size"
  fi
}

# ---------------------------------------------------------------------------
# Strategy: calendar
# ---------------------------------------------------------------------------

_resolve_calendar() {
  local project_root="$1"
  local year month patch_num

  year="$(date +%Y)"
  month="$(date +%-m)"  # No leading zero.

  # CalVer patch: count existing tags matching YYYY.MM.* to derive the next
  # patch number.  When no tags exist for this month, start at 0.
  patch_num=0
  if [ -d "$project_root/.git" ] || git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1; then
    local existing_count
    existing_count="$(cd "$project_root" && git tag -l "${year}.${month}.*" 2>/dev/null | wc -l | tr -d '[:space:]')"
    patch_num="${existing_count:-0}"
  fi

  printf 'strategy=calendar\n'
  printf 'version=%s.%s.%s\n' "$year" "$month" "$patch_num"
}

# ---------------------------------------------------------------------------
# Strategy: manual
# ---------------------------------------------------------------------------

_resolve_manual() {
  printf 'strategy=manual\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  _parse_args "$@"

  local strategy
  strategy="$(_read_strategy "$CONFIG_PATH")"

  # Default to manual when absent (AC4).
  if [ -z "$strategy" ]; then
    strategy="manual"
  fi

  case "$strategy" in
    conventional-commits)
      _resolve_conventional_commits "$PROJECT_ROOT"
      ;;
    manual)
      _resolve_manual
      ;;
    calendar)
      _resolve_calendar "$PROJECT_ROOT"
      ;;
    *)
      _log_err "unknown release.strategy: $strategy (expected: conventional-commits, manual, calendar)"
      exit 2
      ;;
  esac
}

# NFR-052: main-guard — sourcing does not run main.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
