#!/usr/bin/env bash

# Canonical state-tree root.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-}}}"
# transcript-writer.sh — shared per-stack transcript writer helper
#
# Provides three functions:
#   - transcript_path_for(sprint_id, stack)   — emit the canonical transcript path
#   - write_transcript(path)                  — write stdin to path at mode 0600
#   - assert_gitignored(pattern)              — HALT if pattern not in .gitignore
#
# Transcript file convention (.gaia/ canonical):
#   .gaia/memory/checkpoints/sprint-review-{sprint_id}/{stack}.log
#   mode 0600 (umask 077 before creation)
#
# The path lives under `.gaia/memory/checkpoints/` per the framework precedent
# for ephemeral verification artifacts (matches Val envelope sentinel placement).
# Existing `checkpoint-reaper.sh` retention policy applies.
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.

# transcript_path_for <sprint_id> <stack>
#   Emit the canonical transcript path on stdout.
transcript_path_for() {
  local sprint_id="$1"
  local stack="$2"
  if [ -z "$sprint_id" ] || [ -z "$stack" ]; then
    printf 'transcript_path_for: usage: transcript_path_for <sprint_id> <stack>\n' >&2
    return 2
  fi
  printf '%s\n' "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/memory/checkpoints/sprint-review-${sprint_id}/${stack}.log"
}

# write_transcript <path>
#   Read stdin and write to <path> at mode 0600. Creates the parent directory
#   if absent. Uses umask 077 (set before file creation) so the file lands
#   with mode 0600 atomically. Appending semantics — multiple invocations on
#   the same path accumulate content.
write_transcript() {
  local path="$1"
  if [ -z "$path" ]; then
    printf 'write_transcript: usage: write_transcript <path> < <content>\n' >&2
    return 2
  fi
  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  # Create the file with mode 0600 atomically: use a subshell with umask 077
  # to ensure new file creation lands at 0600. Then explicitly chmod 600 to
  # cover the case where the file pre-existed under a different umask (the
  # subshell-scoped umask only affects new files, not chmod on existing).
  ( umask 077; cat >> "$path" )
  chmod 600 "$path"
}

# assert_gitignored <pattern>
#   HALT (non-zero exit) if the given pattern is not ignored by git.
#   Inside a git repo, uses `git check-ignore` anchored to PROJECT_ROOT
#   so the project-root .gitignore is authoritative regardless of CWD.
#   Outside a repo, falls back to a line-by-line .gitignore processor
#   that handles covering directories, negation rules, and treats all
#   patterns literally (no regex or glob expansion).
#   Canonical HALT message format applied.
assert_gitignored() {
  local pattern="$1"
  if [ -z "$pattern" ]; then
    printf 'assert_gitignored: usage: assert_gitignored <pattern>\n' >&2
    return 2
  fi

  # Anchor git operations to PROJECT_ROOT (falls back to CWD via ".").
  local _git_dir="${PROJECT_ROOT:-.}"

  if git -C "$_git_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # git check-ignore needs a concrete path, not a prefix — append a dummy
    # filename so the pattern resolves as a file under the ignored directory.
    if git -C "$_git_dir" check-ignore -q "${pattern}probe" 2>/dev/null; then
      return 0
    fi
    printf 'HALT: %s* must be in .gitignore\n' "$pattern" >&2
    return 1
  fi

  # Non-git fallback: find nearest .gitignore starting from PROJECT_ROOT
  # (or CWD when PROJECT_ROOT is unset).
  local search_dir gitignore
  search_dir="${PROJECT_ROOT:-$(pwd)}"
  while [ "$search_dir" != "/" ]; do
    if [ -f "$search_dir/.gitignore" ]; then
      gitignore="$search_dir/.gitignore"
      break
    fi
    search_dir="$(dirname "$search_dir")"
  done
  if [ -z "${gitignore:-}" ]; then
    printf 'HALT: %s* must be in .gitignore — no .gitignore found\n' "$pattern" >&2
    return 1
  fi

  # Process .gitignore rules in file order (last match wins).  Handles:
  #   - covering directories (rule is an ancestor path of the check path)
  #   - negation rules (! prefix un-ignores a previously matched path)
  #   - literal matching only (no regex/glob — all comparisons are fixed-string)
  local ignored=false line negate rule check
  check="${pattern%/}"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '#'*|'') continue ;; esac
    negate=false
    case "$line" in '!'*) negate=true; line="${line#!}" ;; esac
    rule="${line%/}"
    # Exact match or covering directory (rule is an ancestor of check).
    if [ "$check" = "$rule" ]; then
      if "$negate"; then ignored=false; else ignored=true; fi
    elif [ "${check#"${rule}/"}" != "$check" ]; then
      if "$negate"; then ignored=false; else ignored=true; fi
    # Substring containment (legacy compatibility): check is a fixed
    # substring of rule.  Uses parameter expansion instead of grep to
    # avoid per-line subprocess overhead.
    elif [ "${rule#*"$check"}" != "$rule" ]; then
      if "$negate"; then ignored=false; else ignored=true; fi
    fi
  done < "$gitignore"
  if "$ignored"; then
    return 0
  fi
  printf 'HALT: %s* must be in .gitignore\n' "$pattern" >&2
  return 1
}
