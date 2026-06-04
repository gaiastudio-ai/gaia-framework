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

# Per-project git-state cache (cross-project branch-leak fix). The git-state
# fields (active_branch, git_dirty, line-change counts) are keyed by the
# session's workspace root so concurrent sessions in different repos never
# clobber each other's branch. CACHE_FILE is resolved below (Resolve session
# root) once the workspace root is known. The shared key helper lives under lib/.
_GDC_SELF_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || printf '')"
if [ -r "${_GDC_SELF_DIR}/lib/statusline-project-cache-key.sh" ]; then
  . "${_GDC_SELF_DIR}/lib/statusline-project-cache-key.sh"
elif [ -r "${_GDC_SELF_DIR}/../scripts/lib/statusline-project-cache-key.sh" ]; then
  . "${_GDC_SELF_DIR}/../scripts/lib/statusline-project-cache-key.sh"
fi

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

# ---- Resolve the session workspace root for the per-project cache key -------
# This is the STABLE per-session identity (the terminal's pinned root), NOT the
# probe dir — so the cache file is keyed by which project this session belongs
# to, and concurrent sessions in different repos never share a git-state file.
# Order: payload top-level .cwd -> workspace.current_dir -> PROJECT_PATH.
SESSION_ROOT=""
if [ -n "$HOOK_INPUT" ]; then
  SESSION_ROOT="$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // .workspace.current_dir // ""' 2>/dev/null)"
fi
[ -n "$SESSION_ROOT" ] || SESSION_ROOT="$PROJECT_PATH"

if command -v _statusline_git_state_cache_file >/dev/null 2>&1; then
  CACHE_FILE="$(_statusline_git_state_cache_file "$CACHE_DIR" "$SESSION_ROOT")"
else
  # Helper unavailable (e.g. partial install) — fall back to a session-keyed
  # filename inline so we still never write to the shared global file.
  _CK="$(printf '%s' "$SESSION_ROOT" | cksum 2>/dev/null | awk '{print $1}')"
  [ -n "$_CK" ] || _CK="global"
  CACHE_FILE="${CACHE_DIR}/git-state-${_CK}.json"
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

# ---- Line-change counts (staged + unstaged), AF-2026-05-27-5 --------------
# The statusline shows per-class +added / -removed line counts instead of a
# bare dirty glyph. Capture them here (this is the cache writer; the runtime
# only reads). `git diff --shortstat` prints e.g.
#   " 3 files changed, 30 insertions(+), 4 deletions(-)"
# Either insertions or deletions may be absent. Untracked files contribute no
# line diff (git does not count them) — git_dirty still flips true via the
# porcelain probe above, but the counts stay 0/0 for an untracked-only tree.
# All four owned counts default to 0 and stay 0 on any failure (best-effort).
STAGED_ADDED=0; STAGED_REMOVED=0; UNSTAGED_ADDED=0; UNSTAGED_REMOVED=0

# _parse_shortstat <var_add> <var_rem> <shortstat-line> — set the two named
# vars from a `--shortstat` line. Missing side stays 0. Integer-only.
_parse_shortstat() {
  _ps_va="$1"; _ps_vr="$2"; _ps_line="$3"
  _ps_a=0; _ps_r=0
  case "$_ps_line" in
    *insertion*) _ps_a="$(printf '%s' "$_ps_line" | sed -nE 's/.* ([0-9]+) insertion.*/\1/p')" ;;
  esac
  case "$_ps_line" in
    *deletion*)  _ps_r="$(printf '%s' "$_ps_line" | sed -nE 's/.* ([0-9]+) deletion.*/\1/p')" ;;
  esac
  case "$_ps_a" in ''|*[!0-9]*) _ps_a=0 ;; esac
  case "$_ps_r" in ''|*[!0-9]*) _ps_r=0 ;; esac
  eval "$_ps_va=$_ps_a"
  eval "$_ps_vr=$_ps_r"
}

if [ "${_NO_REPO:-0}" != "1" ] && [ "$GIT_DIRTY" = "true" ]; then
  # Staged vs HEAD (--cached) and unstaged (working tree vs index). Wrapped in
  # the same defensive `|| printf ''` idiom; no timeout needed (diff --shortstat
  # is cheap and the repo was already probed above).
  _SS_STAGED="$(git -C "$PROBE_DIR" diff --cached --shortstat 2>/dev/null || printf '')"
  _SS_UNSTAGED="$(git -C "$PROBE_DIR" diff --shortstat 2>/dev/null || printf '')"
  _parse_shortstat STAGED_ADDED STAGED_REMOVED "$_SS_STAGED"
  _parse_shortstat UNSTAGED_ADDED UNSTAGED_REMOVED "$_SS_UNSTAGED"
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

# Merge owned fields — preserve every other field (e.g. the release-check
# fetcher's keys) verbatim. Owned: git_dirty, active_branch, and the four
# line-change counts (AF-2026-05-27-5).
MERGED="$(printf '%s' "$EXISTING" | jq \
  --argjson gd "$GIT_DIRTY" \
  --argjson ab "$AB_ARG" \
  --argjson sa "$STAGED_ADDED" \
  --argjson sr "$STAGED_REMOVED" \
  --argjson ua "$UNSTAGED_ADDED" \
  --argjson ur "$UNSTAGED_REMOVED" \
  '. + {git_dirty: $gd, active_branch: $ab, staged_added: $sa, staged_removed: $sr, unstaged_added: $ua, unstaged_removed: $ur}' 2>/dev/null)"
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
