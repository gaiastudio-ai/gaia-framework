#!/usr/bin/env bash
# statusline-git-dirty-check.sh — PreToolUse-triggered git state fetcher.
#
# Story: E82-S8 (FR-449, ADR-091 amendment) + sprint-43 active-branch
# extension (issue-2 follow-up to the sprint-42 close).
#
# Role
# ----
# OFF the statusline hot path. Invoked by the Claude Code PreToolUse hook so
# that branch + dirty indicators reflect the agent's actual working repo —
# not the terminal's pinned cwd from `workspace.current_dir` — without
# waiting for the 1h `refreshInterval` cadence.
#
# Probe-directory resolution (PreToolUse stdin → repo)
# ----------------------------------------------------
# The hook reads the PreToolUse JSON payload from stdin and extracts the
# directory the tool call is touching, then resolves that directory's
# enclosing git work tree:
#
#   Write/Edit/Read/NotebookEdit -> dirname(tool_input.file_path)
#   Bash                          -> tool_input.cwd, else leading `cd <dir>`
#                                    in tool_input.command, else top-level cwd
#   anything else                 -> top-level cwd
#   empty/malformed stdin         -> $PROJECT_PATH (legacy fallback)
#
# Then `git -C <probe> rev-parse --show-toplevel` walks up to find the repo.
#
# Read-modify-write contract (ADR-091 amendment)
# ----------------------------------------------
# Both fetchers (`statusline-update-check.sh` and this script) MUST read the
# existing `latest-release.json` cache, merge only their owned fields, and
# atomic-write. Naive `jq -n` overwrite would clobber the other fetcher's
# fields. This script OWNS `git_dirty` AND `active_branch`; preserves
# everything else verbatim.
#
# Owned fields: `git_dirty: bool`, `active_branch: string|null`.
#
# Cache schema (post-merge):
#   {
#     "checked_at_iso": "...",       # owned by update-check
#     "latest_tag": "...",            # owned by update-check
#     "current_tag": "...",           # owned by update-check
#     "update_available": false,      # owned by update-check
#     "installed_version_stale": false,  # owned by update-check (E82-S6)
#     "git_dirty": false,             # owned by this script (E82-S8)
#     "active_branch": "feat/x"       # owned by this script (sprint-43)
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

# ---- Resolve probe directory from PreToolUse stdin ------------------------
# The hook reads the tool-call payload, extracts the file/cwd it's about to
# touch, and uses *that* directory's repo (rather than the pinned
# workspace.current_dir) so the statusline reflects the agent's actual work.
PROBE_DIR=""
HOOK_INPUT=""
if [ ! -t 0 ]; then
  # Stdin is attached (hook context). Drain it with a 1s read timeout so we
  # never block the tool call.
  HOOK_INPUT="$(timeout 1s cat 2>/dev/null || cat 2>/dev/null)"
fi

if [ -n "$HOOK_INPUT" ]; then
  TOOL_NAME="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null)"
  case "$TOOL_NAME" in
    Write|Edit|Read|NotebookEdit)
      _FP="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"
      [ -n "$_FP" ] && PROBE_DIR="$(dirname "$_FP" 2>/dev/null || printf '')"
      ;;
    Bash)
      # Prefer an explicit cwd hint if Claude Code passes one.
      _CWD="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.cwd // ""' 2>/dev/null)"
      if [ -n "$_CWD" ]; then
        PROBE_DIR="$_CWD"
      else
        # Parse a leading `cd <dir>` (or `cd <dir> && ...`) from the command
        # so `cd path/to/repo && git ...` correctly probes path/to/repo.
        _CMD="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)"
        # Match: ^cd <dir> (followed by && or ; or end). Strip surrounding quotes.
        _CD_TARGET="$(printf '%s' "$_CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+["]?([^"&; ]+)["]?[[:space:]]*(&&|;|$).*/\1/p' | head -1)"
        if [ -n "$_CD_TARGET" ]; then
          # If relative, resolve against the top-level cwd from the payload.
          case "$_CD_TARGET" in
            /*) PROBE_DIR="$_CD_TARGET" ;;
            *)
              _TOP_CWD="$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // ""' 2>/dev/null)"
              if [ -n "$_TOP_CWD" ]; then
                PROBE_DIR="${_TOP_CWD}/${_CD_TARGET}"
              else
                PROBE_DIR="$_CD_TARGET"
              fi
              ;;
          esac
        fi
      fi
      ;;
  esac
  # Final per-tool fallback: top-level cwd from the payload.
  if [ -z "$PROBE_DIR" ]; then
    PROBE_DIR="$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // ""' 2>/dev/null)"
  fi
fi

# Ultimate fallback: the legacy PROJECT_PATH.
[ -n "$PROBE_DIR" ] || PROBE_DIR="$PROJECT_PATH"
[ -d "$PROBE_DIR" ] || PROBE_DIR="$PROJECT_PATH"

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
  # The `; printf "RC=%d" $?` trick lets us recover the real probe rc even
  # under `trap 'exit 0' ERR`. Without it, the trap fires before
  # `PROBE_RC=$?` runs and the cache write below is skipped for non-git
  # probe dirs (issue-2 follow-up: clear active_branch when leaving a repo).
  _PROBE_RAW="$(timeout "${GIT_TIMEOUT_SECONDS}s" git -C "$PROBE_DIR" $GIT_ARGS 2>/dev/null; printf 'RC=%d' $?)"
  PROBE_RC="${_PROBE_RAW##*RC=}"
  PORCELAIN_OUTPUT="${_PROBE_RAW%RC=*}"
elif command -v gtimeout >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  _PROBE_RAW="$(gtimeout "${GIT_TIMEOUT_SECONDS}s" git -C "$PROBE_DIR" $GIT_ARGS 2>/dev/null; printf 'RC=%d' $?)"
  PROBE_RC="${_PROBE_RAW##*RC=}"
  PORCELAIN_OUTPUT="${_PROBE_RAW%RC=*}"
else
  # Bash kill-after fallback (stock macOS path).
  # Run git in a subshell, watch its pid, kill if it overruns the budget.
  _TMP_OUT="$(mktemp -t gaia-git-dirty.XXXXXX 2>/dev/null || printf '')"
  if [ -z "$_TMP_OUT" ]; then
    exit 0
  fi
  # shellcheck disable=SC2086
  ( git -C "$PROBE_DIR" $GIT_ARGS >"$_TMP_OUT" 2>/dev/null ) &
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
# AC6: non-git probe dir -> proceed but write empty active_branch so the
# statusline correctly shows "no active branch" instead of stale state from
# the last probe.
if [ "$PROBE_RC" -ne 0 ]; then
  case "$PROBE_RC" in
    124|143)
      # Timeout — leave cache untouched (the previous good state survives).
      exit 0
      ;;
    *)
      # Non-git probe dir — clear active_branch + git_dirty in the cache.
      PORCELAIN_OUTPUT=""
      # Branch capture would also fail; force empty.
      _NO_REPO=1
      ;;
  esac
fi

# Determine dirty bit. Non-empty porcelain output == dirty (any change class:
# modified, untracked, staged, renamed, etc., all surface on porcelain).
if [ -n "$PORCELAIN_OUTPUT" ]; then
  GIT_DIRTY="true"
else
  GIT_DIRTY="false"
fi

# Capture the active branch from the same repo. `git -C <probe>` walks up to
# the enclosing work tree, so this resolves to the branch the agent is
# actually on. Detached HEAD or other failure modes silently produce an
# empty string -> JSON null.
ACTIVE_BRANCH=""
if [ "${_NO_REPO:-0}" != "1" ]; then
  ACTIVE_BRANCH="$(git -C "$PROBE_DIR" symbolic-ref --short HEAD 2>/dev/null || printf '')"
fi

# ---- Read-modify-write cache (ADR-091 amendment) --------------------------
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

# Read existing cache (or {} if absent/unparseable).
if [ -r "$CACHE_FILE" ]; then
  EXISTING="$(jq '.' "$CACHE_FILE" 2>/dev/null || printf '{}')"
else
  EXISTING="{}"
fi

# Build a JSON-safe active_branch value (string when non-empty, null when empty).
if [ -n "$ACTIVE_BRANCH" ]; then
  AB_ARG="$(printf '%s' "$ACTIVE_BRANCH" | jq -Rs '.' 2>/dev/null)"
else
  AB_ARG="null"
fi

# Merge `git_dirty` and `active_branch` — preserve every other field verbatim.
MERGED="$(printf '%s' "$EXISTING" | jq --argjson gd "$GIT_DIRTY" --argjson ab "$AB_ARG" '. + {git_dirty: $gd, active_branch: $ab}' 2>/dev/null)"
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
