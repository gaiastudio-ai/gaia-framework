#!/usr/bin/env bash
# pre-release-sprint-check.sh — pre-release ordering gate.
#
# In concurrent mode, acquires the lifecycle lock (L4) in strict mode,
# checks every per-sprint closing marker, and reports the ids of sprints
# whose state file has status: closed. A sprint with a closing marker
# present is never reported as closed. When any marker is present, polls
# until all markers clear or the lifecycle timeout expires.
#
# In single-sprint mode (max_concurrent_active absent or 1 AND no
# per-sprint state files), the check is a no-op: no lock acquired,
# output unchanged.
#
# Exit codes:
#   0 — success (closed sprint ids on stdout, one per line)
#   3 — lifecycle lock timeout / close in progress
#   4 — symlink detected (strict mode)
#   5 — identity mismatch (strict mode)

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

# Source the lock library.
LOCK_LIB="${PLUGIN_SCRIPTS_DIR}/lib/acquire-lock.sh"
if [ ! -f "$LOCK_LIB" ]; then
  printf 'pre-release-sprint-check: lock library not found at %s\n' "$LOCK_LIB" >&2
  exit 1
fi
# shellcheck source=../../../scripts/lib/acquire-lock.sh
. "$LOCK_LIB"

PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-$PWD}}}"
STATE_DIR="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state"

# Read max_concurrent_active from config.
_max_conc=""
_cfg="${PROJECT_CONFIG:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/config/project-config.yaml}"
if [ -f "$_cfg" ] && command -v yq >/dev/null 2>&1; then
  _max_conc="$(yq '.sprint.max_concurrent_active // ""' "$_cfg" 2>/dev/null)" || _max_conc=""
fi

# Single-sprint mode: no-op.
if ! acquire_lock_is_concurrent_mode "$_max_conc" "$STATE_DIR" 2>/dev/null; then
  exit 0
fi

l4_path="${STATE_DIR}/${GAIA_LOCK_L4_PATH}"
timeout_secs="$GAIA_LOCK_L4_TIMEOUT"
poll_interval="${GAIA_PRE_RELEASE_POLL_INTERVAL:-0.5}"
elapsed=0

# Helper: check if any closing marker exists and return the first sprint id.
_any_closing_marker() {
  local m
  for m in "${STATE_DIR}"/.sprint-closing-*; do
    [ -f "$m" ] || continue
    awk -F= '/^sprint_id=/ { print $2 }' "$m" 2>/dev/null
    return 0
  done
  return 1
}

# Phase 1: acquire L4 and check markers.
_acquire_rc=0
acquire_lock "$l4_path" "$timeout_secs" 8 --strict || _acquire_rc=$?
if [ "$_acquire_rc" -ne 0 ]; then
  # Read marker for diagnostic.
  _blocking=""
  _blocking="$(_any_closing_marker)" || _blocking="another sprint"
  [ -n "$_blocking" ] || _blocking="another sprint"
  printf 'sprint close in progress (sprint %s) -- retry\n' "$_blocking" >&2
  exit "$_acquire_rc"
fi

# Check markers under L4.
_marker_sprint=""
_marker_sprint="$(_any_closing_marker)" || true

if [ -n "$_marker_sprint" ]; then
  # Markers present — release L4 and poll.
  release_lock 8 2>/dev/null || true

  while [ -n "$_marker_sprint" ]; do
    # Check timeout.
    if [ "$(printf '%s >= %s\n' "$elapsed" "$timeout_secs" | bc 2>/dev/null || echo 0)" = "1" ]; then
      printf 'sprint close in progress (sprint %s) -- retry\n' "$_marker_sprint" >&2
      printf 'stale marker may require re-running /gaia-sprint-close --sprint %s\n' "$_marker_sprint" >&2
      exit "$ACQUIRE_LOCK_EXIT_TIMEOUT"
    fi
    sleep "$poll_interval"
    elapsed="$(printf '%s + %s\n' "$elapsed" "$poll_interval" | bc 2>/dev/null || echo "$timeout_secs")"
    _marker_sprint="$(_any_closing_marker)" || true
  done

  # All markers gone — re-acquire L4.
  _acquire_rc=0
  acquire_lock "$l4_path" "$timeout_secs" 8 --strict || _acquire_rc=$?
  if [ "$_acquire_rc" -ne 0 ]; then
    _blocking=""
    _blocking="$(_any_closing_marker)" || _blocking="another sprint"
    [ -n "$_blocking" ] || _blocking="another sprint"
    printf 'sprint close in progress (sprint %s) -- retry\n' "$_blocking" >&2
    exit "$_acquire_rc"
  fi
fi

# Phase 2: enumerate closed sprints from per-sprint state files.
trap 'release_lock 8 2>/dev/null || true' EXIT
trap 'release_lock 8 2>/dev/null || true; exit 130' INT
trap 'release_lock 8 2>/dev/null || true; exit 143' TERM

closed_ids=()
for f in "${STATE_DIR}"/sprint-status-*.yaml; do
  [ -f "$f" ] || continue
  case "$f" in *.lock|*.result) continue ;; esac

  _sid=""
  _sid="$(awk '/^sprint_id:/ { sub(/^sprint_id:[[:space:]]*/, ""); gsub(/"/, ""); gsub(/'\''/, ""); print }' "$f" 2>/dev/null)" || continue
  [ -n "$_sid" ] || continue

  # Skip any sprint that has a closing marker.
  if [ -f "${STATE_DIR}/.sprint-closing-${_sid}" ]; then
    continue
  fi

  _status=""
  _status="$(awk '/^status:/ { sub(/^status:[[:space:]]*/, ""); gsub(/"/, ""); gsub(/'\''/, ""); gsub(/[[:space:]]+$/, ""); print }' "$f" 2>/dev/null)" || continue

  if [ "$_status" = "closed" ]; then
    closed_ids+=("$_sid")
  fi
done

release_lock 8 2>/dev/null || true
trap - EXIT INT TERM

# Output closed sprint ids.
for id in "${closed_ids[@]+"${closed_ids[@]}"}"; do
  printf '%s\n' "$id"
done

exit 0
