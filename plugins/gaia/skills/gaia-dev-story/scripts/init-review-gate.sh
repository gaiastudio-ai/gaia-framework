#!/usr/bin/env bash
# init-review-gate.sh — gaia-dev-story Step 15 Review Gate seeder
#
# Path resolution: this script takes the story_file as a positional argument
# and performs NO docs/ path resolution at the script level. The sibling
# scripts transition-story-status.sh and tdd-review-gate.sh adopt the
# two-stage CLAUDE_PROJECT_ROOT -> PROJECT_PATH -> fallback precedence per
# CLAUDE.md §"Non-git project-root workspace (supported mode)"; this script
# inherits the resolved path from its caller and needs no change.
#
# Purpose:
#   Insert (or replace) the Review Gate table block in a story file with
#   the canonical 6-row UNVERIFIED block. Idempotent — running twice
#   yields the same final file (byte-identical).
#
# Behavior:
#   - Locate the `## Review Gate` heading in the story file.
#   - If present: delete from that heading down to (but not including) the
#                 next H2 heading or EOF, then insert the canonical block in
#                 place.
#   - If absent: append the canonical block at end-of-file.
#
# Canonical block:
#   ## Review Gate
#
#   | Review | Status | Report |
#   |--------|--------|--------|
#   | Code Review | UNVERIFIED | — |
#   | QA Tests | UNVERIFIED | — |
#   | Security Review | UNVERIFIED | — |
#   | Test Automation | UNVERIFIED | — |
#   | Test Review | UNVERIFIED | — |
#   | Performance Review | UNVERIFIED | — |
#
#   > Story moves to `done` only when ALL reviews show PASSED.
#
# Usage:
#   init-review-gate.sh <story_file>
#
# Exit codes:
#   0 — success
#   2 — usage error (no arg, file missing, or file is not writable)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/init-review-gate.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-2}"; }

if [ $# -lt 1 ]; then
  die "usage: init-review-gate.sh <story_file>"
fi

STORY_FILE="$1"
[ -f "$STORY_FILE" ] || die "story file not found: $STORY_FILE"
[ -w "$STORY_FILE" ] || die "story file not writable: $STORY_FILE"

# Build the canonical block. Ends WITHOUT a trailing newline so we can
# append our own deterministic separator below.
read -r -d '' CANONICAL_BLOCK <<'EOF' || true
## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |

> Story moves to `done` only when ALL reviews show PASSED.
EOF

# Working copy to avoid partial writes on error.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Use awk to:
#   - When we hit `## Review Gate`, set skip mode and emit a placeholder
#     marker so we can locate insertion later.
#   - In skip mode, drop everything until we hit the next `## ` heading or
#     EOF; on the next H2, emit the marker BEFORE the heading and continue
#     normally.
#
# Two-pass approach is simpler: pass 1 strips any existing block, pass 2
# appends the canonical block and post-processes.

# Pass 1: strip an existing Review Gate block, if any.
awk '
  BEGIN { skip = 0; found = 0 }
  /^## Review Gate[[:space:]]*$/ { skip = 1; found = 1; next }
  skip == 1 {
    # Re-enter normal mode at the next H2 (and emit that line).
    if ($0 ~ /^## /) { skip = 0; print; next }
    next
  }
  { print }
  END { exit (found ? 10 : 0) }
' "$STORY_FILE" > "$TMP" || stripped_rc=$?

stripped_rc="${stripped_rc:-0}"
# Trim a trailing run of blank lines that might have been left dangling
# after stripping the Review Gate (we re-add exactly one blank line below).
awk '
  { lines[NR] = $0 }
  END {
    last = NR
    while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
    for (i = 1; i <= last; i++) print lines[i]
  }
' "$TMP" > "$TMP.trim"
mv "$TMP.trim" "$TMP"

# Append the canonical block. Always insert one blank line before, and one
# trailing newline at EOF for POSIX-friendliness.
{
  cat "$TMP"
  printf '\n\n'
  printf '%s\n' "$CANONICAL_BLOCK"
} > "$TMP.final"

mv "$TMP.final" "$STORY_FILE"

log "Review Gate seeded in $STORY_FILE (existing block ${stripped_rc:+replaced}${stripped_rc:-fresh})"
exit 0
