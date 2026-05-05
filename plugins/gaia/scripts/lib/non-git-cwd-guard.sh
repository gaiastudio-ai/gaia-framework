#!/usr/bin/env bash
# non-git-cwd-guard.sh — shared "skip-with-warning on non-git CWD" guard.
#
# Story: E53-S234 — Document non-git docs/ workspace + degrade git ops gracefully.
# Anchor ADRs: ADR-070 (docs reorganization), ADR-072 (atomic rename guarantees).
#
# Background:
#   The project root layout supports a non-git docs/ workspace — the directory
#   that holds docs/, _memory/, and CLAUDE.md is not always inside a git work
#   tree. /gaia-dev-story Steps 10-13 (push, PR, CI, merge) are gated on this
#   guard so the workflow degrades gracefully instead of HALT-ing when a story
#   touches only non-git artifacts.
#
# Contract:
#   This file is intended to be SOURCED, not executed. Sourcing makes
#   `non_git_cwd_skip` available; calling it from a guarded script emits a
#   "skipped (non-git CWD)" warning to stderr and exits 0 when CWD is not
#   inside a git work tree.
#
# Usage (canonical idiom in the seven guarded scripts):
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=...
#   . "$SCRIPT_DIR/<relative path>/lib/non-git-cwd-guard.sh"
#   non_git_cwd_skip "$SCRIPT_NAME" || exit 0
#
#   # Equivalently, if `non_git_cwd_skip` returns 0 (= we ARE inside a git
#   # work tree) we fall through to the script's normal logic. If it returns
#   # non-zero (= we ARE outside any git work tree) it has already emitted
#   # the canonical warning to stderr and the caller exits 0 silently.
#
# The guard always reads CWD via `git rev-parse --is-inside-work-tree`. Any
# non-zero result from git (including "fatal: not a git repository") is
# treated as "outside any git work tree" and triggers the skip.

# Refuse to be executed directly. Sourcing semantics depend on shell.
if [ "${BASH_SOURCE[0]:-$0}" = "${0:-}" ] && [ -z "${BASH_SOURCE+x}" ]; then
  printf 'non-git-cwd-guard.sh: must be sourced, not executed\n' >&2
  exit 1
fi

# non_git_cwd_skip <script-name>
#
# Returns:
#   0 — CWD IS inside a git work tree; the caller should continue normal flow.
#   1 — CWD is NOT inside any git work tree; the function has emitted a
#       "skipped (non-git CWD)" warning to stderr and the caller should exit 0.
#
# Argument:
#   <script-name> — used as the stderr log prefix (e.g. "gaia-dev-story/git-branch.sh").
#                   Falls back to "${0##*/}" if omitted.
non_git_cwd_skip() {
  local prefix="${1:-${0##*/}}"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  printf '%s: skipped (non-git CWD) — git ops require an in-tree repo (gaia-public/, gaia-enterprise/, Gaia-framework/). See ADR-070/ADR-072 non-git workspace subsection.\n' \
    "$prefix" >&2
  return 1
}
