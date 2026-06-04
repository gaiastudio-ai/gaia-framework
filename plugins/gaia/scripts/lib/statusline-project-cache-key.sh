#!/usr/bin/env bash
# statusline-project-cache-key.sh — shared helper that derives a per-project
# cache path for the statusline's git-state fields (active_branch, git_dirty,
# and the four line-change counts).
#
# Background (cross-project branch leak)
# --------------------------------------
# Before this helper, `statusline-git-dirty-check.sh` (the PreToolUse hook) and
# `statusline.sh` (the renderer) both read/wrote git state to ONE global file:
#   $HOME/.claude/gaia-statusline/cache/latest-release.json
# That file is shared by every concurrent Claude Code session. With two
# terminals open on two different repos, whichever session's hook fired last
# overwrote `active_branch` — so the second project's statusline displayed the
# FIRST project's branch. The version-check fields in that file are genuinely
# global (project-agnostic), but the git-state fields are per-session and must
# be isolated.
#
# Fix: store the per-project git state in a file keyed by the session's
# workspace root, so each project gets its own active_branch / git_dirty:
#   $HOME/.claude/gaia-statusline/cache/git-state-<key>.json
# where <key> is a deterministic, filesystem-safe digest of the workspace root.
#
# Both the writer and the reader resolve the SAME workspace root (the renderer's
# `workspace.current_dir`, which equals the hook payload's top-level `.cwd`), so
# they agree on the key without any cross-process coordination.
#
# Portability: uses `cksum` (POSIX, always present) for the digest — no
# dependency on shasum/md5 which are not in the statusline tool allowlist.
# bash 3.2 / LC_ALL=C clean. Sourceable, idempotent source guard.

if [ "${_GAIA_STATUSLINE_PROJECT_CACHE_KEY_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# _statusline_project_cache_key ROOT — print a deterministic, filesystem-safe
# key for the given workspace root. Empty ROOT yields the literal key "global"
# so callers degrade to a single shared file rather than an empty filename.
_statusline_project_cache_key() {
  local root="$1" digest
  if [ -z "$root" ]; then
    printf 'global'
    return 0
  fi
  # cksum emits "<crc> <bytecount>"; take the CRC field. Digits only — safe in
  # a filename on every filesystem.
  digest="$(printf '%s' "$root" | cksum 2>/dev/null | awk '{print $1}')"
  if [ -z "$digest" ]; then
    digest='global'
  fi
  printf '%s' "$digest"
}

# _statusline_git_state_cache_file CACHE_DIR ROOT — print the absolute path to
# the per-project git-state cache file for the given workspace root.
_statusline_git_state_cache_file() {
  local cache_dir="$1" root="$2" key
  key="$(_statusline_project_cache_key "$root")"
  printf '%s/git-state-%s.json' "$cache_dir" "$key"
}

_GAIA_STATUSLINE_PROJECT_CACHE_KEY_LOADED=1
