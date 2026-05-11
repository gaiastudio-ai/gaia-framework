#!/usr/bin/env bash
# statusline-git-dirty-check.sh — PreToolUse-triggered git-dirty fetcher.
#
# Story: E82-S8 (FR-449, ADR-091 amendment).
#
# Role
# ----
# OFF the statusline hot path. Invoked by the Claude Code PreToolUse hook so
# that BRANCH-chunk dirty indicators reflect intent-to-mutate state without
# waiting for the 1h `refreshInterval` cadence.
#
# Read-modify-write contract (ADR-091 amendment)
# ----------------------------------------------
# Both fetchers (`statusline-update-check.sh` and this script) MUST read the
# existing `latest-release.json` cache, merge only their owned field, and
# atomic-write. Naive `jq -n` overwrite would clobber the other fetcher's
# fields. This script OWNS `git_dirty`; preserves everything else verbatim.
#
# Owned field: `git_dirty: bool` only.
#
# Cache schema (post-merge):
#   {
#     "checked_at_iso": "...",       # owned by update-check
#     "latest_tag": "...",            # owned by update-check
#     "current_tag": "...",           # owned by update-check
#     "update_available": false,      # owned by update-check
#     "installed_version_stale": false,  # owned by update-check (E82-S6)
#     "git_dirty": false              # owned by this script (E82-S8)
#   }
#
# Failure-mode philosophy
# -----------------------
# Every failure is silent: exit 0, cache untouched, nothing on stderr. The
# statusline renderer degrades cleanly (BRANCH chunk renders without the
# dirty glyph if `git_dirty` is missing or `false`).
#
# Atomic write (NFR-STATUSLINE-3)
# -------------------------------
# Sibling-tempfile + `mv -f` on the same filesystem as the cache target.
# Crossing filesystems via /tmp breaks rename atomicity.
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -u
LC_ALL=C
export LC_ALL

trap 'exit 0' ERR

SIBLING=""
_cleanup() {
  if [ -n "${SIBLING:-}" ] && [ -e "$SIBLING" ]; then
    rm -f "$SIBLING" 2>/dev/null || true
  fi
}
trap _cleanup EXIT INT TERM

# ---- Constants -------------------------------------------------------------
GIT_TIMEOUT_SECONDS=2

CACHE_DIR="${HOME}/.claude/gaia-statusline/cache"
CACHE_FILE="${CACHE_DIR}/latest-release.json"

# Resolve PROJECT_PATH (caller / hook injection / CWD).
PROJECT_PATH="${PROJECT_PATH:-$PWD}"

# Bail fast if jq is missing — without it we cannot read or merge.
command -v jq >/dev/null 2>&1 || exit 0

# ---- Probe git status with a portable timeout -----------------------------
# AC9: macOS lacks GNU `timeout`. Chain: timeout -> gtimeout -> bash kill-after.
# Each branch produces $PORCELAIN_OUTPUT (possibly empty) and $PROBE_RC.
PORCELAIN_OUTPUT=""
PROBE_RC=0
GIT_ARGS="status --porcelain"
if [ "${GAIA_STATUSLINE_DIRTY_RECURSE_SUBMODULES:-0}" = "1" ]; then
  GIT_ARGS="status --porcelain --recurse-submodules"
fi

if command -v timeout >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  PORCELAIN_OUTPUT="$(timeout "${GIT_TIMEOUT_SECONDS}s" git -C "$PROJECT_PATH" $GIT_ARGS 2>/dev/null)"
  PROBE_RC=$?
elif command -v gtimeout >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  PORCELAIN_OUTPUT="$(gtimeout "${GIT_TIMEOUT_SECONDS}s" git -C "$PROJECT_PATH" $GIT_ARGS 2>/dev/null)"
  PROBE_RC=$?
else
  # Bash kill-after fallback (stock macOS path).
  # Run git in a subshell, watch its pid, kill if it overruns the budget.
  _TMP_OUT="$(mktemp -t gaia-git-dirty.XXXXXX 2>/dev/null || printf '')"
  if [ -z "$_TMP_OUT" ]; then
    exit 0
  fi
  # shellcheck disable=SC2086
  ( git -C "$PROJECT_PATH" $GIT_ARGS >"$_TMP_OUT" 2>/dev/null ) &
  _GIT_PID=$!
  (
    sleep "$GIT_TIMEOUT_SECONDS"
    if kill -0 "$_GIT_PID" 2>/dev/null; then
      kill "$_GIT_PID" 2>/dev/null || true
    fi
  ) &
  _KILLER_PID=$!
  wait "$_GIT_PID" 2>/dev/null
  PROBE_RC=$?
  kill "$_KILLER_PID" 2>/dev/null || true
  wait "$_KILLER_PID" 2>/dev/null || true
  PORCELAIN_OUTPUT="$(cat "$_TMP_OUT" 2>/dev/null || printf '')"
  rm -f "$_TMP_OUT" 2>/dev/null || true
fi

# AC5: timeout (exit 124 from `timeout` / 143 from kill) -> silent exit 0.
# AC6: non-git CWD (git exits non-zero) -> silent exit 0.
# Both classes converge on PROBE_RC != 0 -> bail cleanly without writing.
if [ "$PROBE_RC" -ne 0 ]; then
  exit 0
fi

# Determine dirty bit. Non-empty porcelain output == dirty (any change class:
# modified, untracked, staged, renamed, etc., all surface on porcelain).
if [ -n "$PORCELAIN_OUTPUT" ]; then
  GIT_DIRTY="true"
else
  GIT_DIRTY="false"
fi

# ---- Read-modify-write cache (ADR-091 amendment) --------------------------
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

# Read existing cache (or {} if absent/unparseable).
if [ -r "$CACHE_FILE" ]; then
  EXISTING="$(jq '.' "$CACHE_FILE" 2>/dev/null || printf '{}')"
else
  EXISTING="{}"
fi

# Merge only `git_dirty` — preserve every other field verbatim.
MERGED="$(printf '%s' "$EXISTING" | jq --argjson gd "$GIT_DIRTY" '. + {git_dirty: $gd}' 2>/dev/null)"
if [ -z "$MERGED" ]; then
  exit 0
fi

SIBLING="$(mktemp "${CACHE_FILE}.XXXXXX" 2>/dev/null || printf '')"
if [ -z "$SIBLING" ]; then
  exit 0
fi

printf '%s\n' "$MERGED" > "$SIBLING" 2>/dev/null || {
  rm -f "$SIBLING" 2>/dev/null
  exit 0
}

mv -f "$SIBLING" "$CACHE_FILE" 2>/dev/null || rm -f "$SIBLING" 2>/dev/null

exit 0
