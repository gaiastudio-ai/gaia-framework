#!/usr/bin/env bash
# approve-baseline.sh — human-in-the-loop baseline approval.
# Requires interactive terminal; refuses on non-tty stdin.
#
# Usage:
#   approve-baseline.sh --story <slug> --breakpoint <width>
#                       [--all] [--project-root <dir>]
#                       [--screenshot-dir <dir>] [--config <path>]
#
# The --all flag iterates all configured breakpoints with per-breakpoint consent.
# NEVER auto-accepts: every baseline update requires explicit y/yes confirmation.

set -euo pipefail

SCRIPT_NAME="approve-baseline.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- Public function ----------

approve_single_breakpoint() {
  local story_slug="$1"
  local breakpoint="$2"
  local baseline_dir="$3"
  local screenshot_dir="$4"

  local baseline_file="$baseline_dir/baseline-${breakpoint}.png"
  local screenshot_file="$screenshot_dir/screenshot-${breakpoint}.png"

  if [ ! -f "$screenshot_file" ]; then
    log "no screenshot found for breakpoint ${breakpoint}: $screenshot_file"
    return 1
  fi

  # Defense-in-depth: refuse when stdin is non-interactive AND no
  # confirmation token is available.  Piped input (echo "y" | ...) is
  # allowed — the guard fires only when read returns empty/EOF from a
  # non-tty fd (e.g. </dev/null or backgrounded process).
  printf 'Approve new baseline for %s at %spx? [y/N] ' "$story_slug" "$breakpoint"
  local answer=""
  read -r answer || true

  if ! [ -t 0 ] && [ -z "$answer" ]; then
    log "non-interactive context with no confirmation; baseline write refused"
    return 1
  fi

  case "$answer" in
    y|Y|yes|YES)
      # Archive old baseline if it exists
      if [ -f "$baseline_file" ]; then
        local timestamp
        timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
        local archive_name
        archive_name="$(dirname "$baseline_file")/previous"
        mkdir -p "$archive_name"
        cp "$baseline_file" "$archive_name/baseline-${breakpoint}-${timestamp}.png"
        log "archived old baseline to $archive_name/baseline-${breakpoint}-${timestamp}.png"
      fi

      # Copy new screenshot to baseline location
      mkdir -p "$(dirname "$baseline_file")"
      cp "$screenshot_file" "$baseline_file"
      log "updated baseline: $baseline_file"

      # Audit log
      local audit_log
      audit_log="$(dirname "$baseline_dir")/baseline-approvals.log"
      printf '%s approved baseline-%s.png for %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$breakpoint" "$story_slug" \
        >> "$audit_log"
      ;;
    *)
      log "declined baseline update for breakpoint ${breakpoint}"
      return 1
      ;;
  esac
}

# ---------- _main guard ----------

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  # Refuse on non-tty stdin
  if ! [ -t 0 ]; then
    die "interactive terminal required; baseline approval cannot run in non-tty mode"
  fi

  STORY=""
  BREAKPOINT=""
  ALL=0
  PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-${PROJECT_ROOT:-${PROJECT_PATH:-${PWD}}}}}"
  SCREENSHOT_DIR=""
  CONFIG_PATH=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --story)          [ $# -ge 2 ] || die "--story requires a value"; STORY="$2"; shift 2 ;;
      --breakpoint)     [ $# -ge 2 ] || die "--breakpoint requires a value"; BREAKPOINT="$2"; shift 2 ;;
      --all)            ALL=1; shift ;;
      --project-root)   [ $# -ge 2 ] || die "--project-root requires a value"; PROJECT_ROOT="$2"; shift 2 ;;
      --screenshot-dir) [ $# -ge 2 ] || die "--screenshot-dir requires a path"; SCREENSHOT_DIR="$2"; shift 2 ;;
      --config)         [ $# -ge 2 ] || die "--config requires a path"; CONFIG_PATH="$2"; shift 2 ;;
      *)                die "unknown argument: $1" ;;
    esac
  done

  [ -n "$STORY" ] || die "usage: --story is required"

  if [ -z "$CONFIG_PATH" ]; then
    CONFIG_PATH="${PROJECT_ROOT}/.gaia/config/project-config.yaml"
  fi

  # Resolve baseline directory
  RESOLVER="$(cd "$SCRIPT_DIR/../../../../scripts/lib" && pwd)/resolve-artifact-path.sh"
  BASELINE_DIR="$(bash "$RESOLVER" design_baselines --slug "$STORY" \
    --project-root "$PROJECT_ROOT" 2>/dev/null || true)"

  if [ -z "$BASELINE_DIR" ]; then
    die "could not resolve baseline directory for story $STORY"
  fi

  mkdir -p "$BASELINE_DIR"

  if [ "$ALL" -eq 1 ]; then
    # Source config reader for breakpoints
    # shellcheck source=read-visual-diff-config.sh
    source "$SCRIPT_DIR/read-visual-diff-config.sh"
    breakpoints_raw="$(read_breakpoints "$CONFIG_PATH")"

    while IFS= read -r bp; do
      [ -n "$bp" ] || continue
      approve_single_breakpoint "$STORY" "$bp" "$BASELINE_DIR" "$SCREENSHOT_DIR" || true
    done <<< "$breakpoints_raw"
  else
    [ -n "$BREAKPOINT" ] || die "usage: --breakpoint is required (or use --all)"
    approve_single_breakpoint "$STORY" "$BREAKPOINT" "$BASELINE_DIR" "$SCREENSHOT_DIR"
  fi
fi
