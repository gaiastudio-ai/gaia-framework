#!/usr/bin/env bash
# plugin-cache-recovery.sh — GAIA foundation script
#
# Detects and recovers from a polluted Claude Code plugin marketplace cache.
# Automates the manual recipe documented in README.md so users (and support
# channels) have a deterministic, auditable alternative to an unguided
# `rm -rf ~/.claude/plugins/marketplaces/...`.
#
# Background:
#   When `/plugin marketplace add <owner>/<repo>` fails mid-clone (transient
#   network error, DNS blip, interrupted download, partial tar extraction),
#   Claude Code can leave a broken clone cached under
#   ~/.claude/plugins/marketplaces/<slug>/. Every subsequent `marketplace add`
#   short-circuits on the cache entry and fails with the same error. The
#   user-visible symptom is a marketplace that refuses to install no matter
#   how many times you retry.
#
#   The fix is to clear the polluted cache entry and retry. This script
#   encodes that fix so it can run:
#     - interactively from a terminal,
#     - non-interactively from a /gaia-* workflow step,
#     - under CI in smoke-test mode (no real $HOME writes).
#
# Usage:
#   plugin-cache-recovery.sh --slug <marketplace-slug>
#                            [--cache-root <dir>]
#                            [--dry-run]
#                            [--force]
#                            [--quiet]
#   plugin-cache-recovery.sh --detect --slug <marketplace-slug>
#                            [--cache-root <dir>]
#   plugin-cache-recovery.sh --list [--cache-root <dir>]
#   plugin-cache-recovery.sh --help
#
# Slug format:
#   <owner>-<repo>  (matches the directory name Claude Code creates under
#                    ~/.claude/plugins/marketplaces/). Alphanumerics, dashes,
#                    underscores, and dots only — no slashes, no "..", no
#                    leading "-". Rejecting everything else is how we keep
#                    the rm -rf inside --cache-root.
#
# Examples:
#   plugin-cache-recovery.sh --slug gaiastudio-ai-gaia-framework
#   plugin-cache-recovery.sh --slug gaiastudio-ai-gaia-enterprise --dry-run
#   plugin-cache-recovery.sh --detect --slug gaiastudio-ai-gaia-framework
#
# Exit codes:
#   0 — cache entry cleared, already absent, or detect reports clean
#   1 — usage error, invalid slug, path-traversal attempt, refusal without
#       --force when the cache entry looks like a healthy git clone
#   2 — detect reports a polluted or stale entry (detect mode only)
#   3 — filesystem error during removal
#
# Contract for CI / bats-core:
#   - --cache-root overrides $HOME/.claude/plugins/marketplaces so tests
#     never touch a real home directory.
#   - --dry-run prints the intended rm target to stdout and exits 0 without
#     touching the filesystem.
#   - stderr is reserved for errors and warnings; stdout is reserved for
#     machine-parseable status lines prefixed `plugin-cache-recovery:`.
#
set -uo pipefail
LC_ALL=C

PROG="plugin-cache-recovery"

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

log()  { [ "${QUIET:-0}" = "1" ] || printf '%s: %s\n' "$PROG" "$*"; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
err()  { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

MODE="clear"          # clear | detect | list
SLUG=""
CACHE_ROOT=""
DRY_RUN=0
FORCE=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --slug)
      [ $# -ge 2 ] || { err "--slug requires a value"; exit 1; }
      SLUG="$2"
      shift 2
      ;;
    --cache-root)
      [ $# -ge 2 ] || { err "--cache-root requires a value"; exit 1; }
      CACHE_ROOT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --detect)
      MODE="detect"
      shift
      ;;
    --list)
      MODE="list"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      err "unknown flag: $1"
      exit 1
      ;;
    *)
      err "unexpected positional argument: $1"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve cache root
# ---------------------------------------------------------------------------

if [ -z "$CACHE_ROOT" ]; then
  if [ -n "${PLUGIN_CACHE_ROOT:-}" ]; then
    CACHE_ROOT="$PLUGIN_CACHE_ROOT"
  else
    CACHE_ROOT="${HOME:-}/.claude/plugins/marketplaces"
  fi
fi

# We never mkdir -p the cache root. If it does not exist, there is nothing
# to recover — every mode treats that as success (clear/detect) or empty list.
# This keeps the script idempotent and safe to call unconditionally from
# workflow steps.

# ---------------------------------------------------------------------------
# Slug validation — the only thing standing between us and `rm -rf $HOME`
# ---------------------------------------------------------------------------

validate_slug() {
  local s="$1"
  if [ -z "$s" ]; then
    err "--slug is required"
    return 1
  fi
  case "$s" in
    */*|*..*|.*|-*)
      err "invalid slug (path traversal or leading dot/dash): $s"
      return 1
      ;;
  esac
  # Whitelist: alnum, dash, underscore, dot.
  case "$s" in
    *[!a-zA-Z0-9._-]*)
      err "invalid slug (only [a-zA-Z0-9._-] allowed): $s"
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Cache entry classification
# ---------------------------------------------------------------------------
#
# A cache entry is classified as one of:
#   absent   — no directory at all (clean state, nothing to do)
#   healthy  — directory exists, is a git repo, and the clone looks complete
#              (has .git/HEAD and at least one tracked file at the top level)
#   polluted — directory exists but fails the healthy check (partial clone,
#              corrupted index, empty dir, non-git dir, missing HEAD)
#
# Only `polluted` triggers automatic removal. `healthy` requires --force so
# we never silently nuke a working install that a user asked us to leave
# alone.

classify_entry() {
  local entry="$1"
  if [ ! -e "$entry" ]; then
    printf 'absent'
    return 0
  fi
  if [ ! -d "$entry" ]; then
    # A file where a directory should be is always broken.
    printf 'polluted'
    return 0
  fi
  # Empty directory → polluted.
  if [ -z "$(ls -A "$entry" 2>/dev/null || true)" ]; then
    printf 'polluted'
    return 0
  fi
  # Not a git repo → polluted.
  if [ ! -e "$entry/.git" ]; then
    printf 'polluted'
    return 0
  fi
  # git dir but missing HEAD → polluted.
  if [ ! -e "$entry/.git/HEAD" ] && [ ! -f "$entry/HEAD" ]; then
    printf 'polluted'
    return 0
  fi
  # Healthy-looking clone.
  printf 'healthy'
  return 0
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

mode_list() {
  if [ ! -d "$CACHE_ROOT" ]; then
    log "cache root absent: $CACHE_ROOT"
    return 0
  fi
  local count=0
  local name entry state
  for entry in "$CACHE_ROOT"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    state="$(classify_entry "$entry")"
    printf '%s\t%s\n' "$name" "$state"
    count=$((count + 1))
  done
  [ "$count" -eq 0 ] && log "no cache entries under $CACHE_ROOT"
  return 0
}

mode_detect() {
  validate_slug "$SLUG" || return 1
  local entry="$CACHE_ROOT/$SLUG"
  local state
  state="$(classify_entry "$entry")"
  case "$state" in
    absent)
      log "absent: $entry"
      return 0
      ;;
    healthy)
      log "healthy: $entry"
      return 0
      ;;
    polluted)
      log "polluted: $entry"
      return 2
      ;;
  esac
  return 1
}

mode_clear() {
  validate_slug "$SLUG" || return 1
  local entry="$CACHE_ROOT/$SLUG"

  # Defense-in-depth: even with slug validation, confirm the resolved entry
  # lives under the configured cache root. This catches future bugs where
  # CACHE_ROOT or SLUG is joined with an unexpected separator.
  case "$entry" in
    "$CACHE_ROOT"/*) ;;
    *)
      err "refusing to remove path outside cache root: $entry"
      return 1
      ;;
  esac

  local state
  state="$(classify_entry "$entry")"

  case "$state" in
    absent)
      log "already clean: $entry"
      return 0
      ;;
    healthy)
      if [ "$FORCE" != "1" ]; then
        err "entry looks healthy; pass --force to remove anyway: $entry"
        return 1
      fi
      warn "removing healthy entry because --force was set: $entry"
      ;;
    polluted)
      log "polluted entry detected: $entry"
      ;;
  esac

  if [ "$DRY_RUN" = "1" ]; then
    log "dry-run: would remove $entry"
    return 0
  fi

  if rm -rf -- "$entry"; then
    log "removed: $entry"
    log "next: run '/plugin marketplace add <owner>/<repo>' in Claude Code"
    return 0
  else
    err "rm failed for $entry"
    return 3
  fi
}

case "$MODE" in
  clear)  mode_clear  ;;
  detect) mode_detect ;;
  list)   mode_list   ;;
  *)      err "internal error: unknown mode $MODE"; exit 1 ;;
esac
