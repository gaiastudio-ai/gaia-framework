#!/usr/bin/env bash
# transcript-writer.sh — shared per-stack transcript writer helper (E93-S4)
#
# Provides three functions:
#   - transcript_path_for(sprint_id, stack)   — emit the canonical transcript path
#   - write_transcript(path)                  — write stdin to path at mode 0600
#   - assert_gitignored(pattern)              — HALT if pattern not in .gitignore
#
# Transcript file convention (AF-2026-05-27-3 / ADR-111 — .gaia/ canonical):
#   .gaia/memory/checkpoints/sprint-review-{sprint_id}/{stack}.log
#   mode 0600 (umask 077 before creation)
#
# The path lives under `.gaia/memory/checkpoints/` per the framework precedent
# for ephemeral verification artifacts (matches Val envelope sentinel placement).
# Existing `checkpoint-reaper.sh` retention policy applies.
#
# Traces to: AC5 of E93-S4, T-SGR-7, SR-65, SR-67.
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
  printf '%s\n' ".gaia/memory/checkpoints/sprint-review-${sprint_id}/${stack}.log"
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
#   HALT (non-zero exit) if `.gitignore` does not contain a line matching
#   the given pattern. Walks up from CWD to find the nearest `.gitignore`.
#   Canonical HALT message per SR-65.
assert_gitignored() {
  local pattern="$1"
  if [ -z "$pattern" ]; then
    printf 'assert_gitignored: usage: assert_gitignored <pattern>\n' >&2
    return 2
  fi
  # Find nearest .gitignore by walking up from CWD.
  local cwd gitignore
  cwd="$(pwd)"
  while [ "$cwd" != "/" ]; do
    if [ -f "$cwd/.gitignore" ]; then
      gitignore="$cwd/.gitignore"
      break
    fi
    cwd="$(dirname "$cwd")"
  done
  if [ -z "${gitignore:-}" ]; then
    printf 'HALT: %s* must be in .gitignore (T-SGR-7/SR-65) — no .gitignore found\n' "$pattern" >&2
    return 1
  fi
  # Match either literal prefix line or a wildcard form covering the pattern.
  if grep -Fq "$pattern" "$gitignore"; then
    return 0
  fi
  printf 'HALT: %s* must be in .gitignore (T-SGR-7/SR-65)\n' "$pattern" >&2
  return 1
}
