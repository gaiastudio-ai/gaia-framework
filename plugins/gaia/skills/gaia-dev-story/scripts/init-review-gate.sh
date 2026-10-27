#!/usr/bin/env bash
# init-review-gate.sh — gaia-dev-story Review Gate seeder (non-destructive)
#
# Path resolution: this script takes the story_file as a positional argument
# and performs NO docs/ path resolution at the script level. The sibling
# scripts transition-story-status.sh and tdd-review-gate.sh adopt the
# two-stage CLAUDE_PROJECT_ROOT -> PROJECT_PATH -> fallback precedence;
# this script inherits the resolved path from its caller and needs no change.
#
# Purpose:
#   Ensure the story file has all six canonical Review Gate rows. Existing
#   verdicts are preserved — only missing rows are seeded with UNVERIFIED.
#   This makes the initialization non-destructive and idempotent.
#
# Behavior:
#   - If `## Review Gate` is absent: append the canonical six-row block.
#   - If `## Review Gate` is present: parse existing rows and seed only the
#     missing canonical rows with UNVERIFIED. Existing verdicts (PASSED,
#     FAILED, UNVERIFIED) are never overwritten.
#
# Canonical rows (exact names, exact order):
#   "Code Review" | "QA Tests" | "Security Review"
#   "Test Automation" | "Test Review" | "Performance Review"
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

# Canonical gate names in order.
CANONICAL_GATES=(
  "Code Review"
  "QA Tests"
  "Security Review"
  "Test Automation"
  "Test Review"
  "Performance Review"
)

# Working copy to avoid partial writes on error.
TMP="$(mktemp)"
MISSING_FILE="$(mktemp)"
trap 'rm -f "$TMP" "${TMP}.new" "$MISSING_FILE"' EXIT

# Check if the ## Review Gate section exists.
has_section=0
if grep -q '^## Review Gate[[:space:]]*$' "$STORY_FILE"; then
  has_section=1
fi

if [ "$has_section" -eq 0 ]; then
  # No section — append the full canonical block at the end.
  # Trim trailing blank lines first.
  awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = 1; i <= last; i++) print lines[i]
    }
  ' "$STORY_FILE" > "$TMP"

  {
    cat "$TMP"
    printf '\n\n## Review Gate\n\n'
    printf '| Review | Status | Report | Reviewed SHA |\n'
    printf '|--------|--------|--------|--------------|  \n'
    for g in "${CANONICAL_GATES[@]}"; do
      printf '| %s | UNVERIFIED | — |  |\n' "$g"
    done
    printf '\n> Story moves to `done` only when ALL reviews show PASSED.\n'
  } > "${TMP}.new"

  mv "${TMP}.new" "$STORY_FILE"
  log "Review Gate seeded in $STORY_FILE (fresh block)"
  exit 0
fi

# Section exists — parse existing rows to find which are present.
existing_gates=""
while IFS=$'\t' read -r gate _status _report _rest; do
  [ -z "$gate" ] && continue
  existing_gates="${existing_gates}|${gate}|"
done < <(awk '
  BEGIN { in_section = 0; in_table = 0; saw_sep = 0 }
  /^## Review Gate[[:space:]]*$/ { in_section = 1; in_table = 0; saw_sep = 0; next }
  in_section && /^## / { in_section = 0; in_table = 0; next }
  !in_section { next }
  { sub(/\r$/, "", $0) }
  in_section && !in_table {
    if ($0 ~ /^[[:space:]]*\|/) { in_table = 1; saw_sep = 0 }
    next
  }
  in_table {
    if ($0 !~ /^[[:space:]]*\|/) { in_table = 0; in_section = 0; next }
    if (!saw_sep && $0 ~ /^[[:space:]]*\|[[:space:]]*-+/) { saw_sep = 1; next }
    line = $0
    sub(/^[[:space:]]*\|/, "", line)
    sub(/\|[[:space:]]*$/, "", line)
    n = split(line, cells, /\|/)
    if (n < 3) next
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", cells[1])
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", cells[2])
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", cells[3])
    printf "%s\t%s\t%s\n", cells[1], cells[2], cells[3]
  }
' "$STORY_FILE")

# Build the list of missing rows into a temp file.
missing_count=0
: > "$MISSING_FILE"
for g in "${CANONICAL_GATES[@]}"; do
  case "$existing_gates" in
    *"|${g}|"*) ;;
    *)
      printf '| %s | UNVERIFIED | — |\n' "$g" >> "$MISSING_FILE"
      missing_count=$((missing_count + 1))
      ;;
  esac
done

if [ "$missing_count" -eq 0 ]; then
  log "Review Gate in $STORY_FILE already has all 6 canonical rows (no changes)"
  exit 0
fi

# Insert missing rows at the end of the existing table (before the blockquote
# or next section). Use awk with the missing rows in a separate file.
GAIA_MISSING_FILE="$MISSING_FILE" awk '
  BEGIN {
    in_section = 0; in_table = 0; saw_sep = 0; inserted = 0
    missing_file = ENVIRON["GAIA_MISSING_FILE"]
  }

  /^## Review Gate[[:space:]]*$/ {
    in_section = 1; in_table = 0; saw_sep = 0
    print
    next
  }

  in_section && /^## / && !/^## Review Gate/ {
    if (!inserted) { while ((getline ml < missing_file) > 0) print ml; inserted = 1 }
    in_section = 0; in_table = 0
    print
    next
  }

  !in_section { print; next }

  in_section && !in_table {
    if ($0 ~ /^[[:space:]]*\|/) {
      in_table = 1; saw_sep = 0
    }
    print
    next
  }

  in_table {
    if ($0 !~ /^[[:space:]]*\|/) {
      if (!inserted) { while ((getline ml < missing_file) > 0) print ml; inserted = 1 }
      in_table = 0
      print
      next
    }
    if (!saw_sep && $0 ~ /^[[:space:]]*\|[[:space:]]*-+/) {
      saw_sep = 1
      print
      next
    }
    print
    next
  }

  { print }

  END {
    if (in_table && !inserted) { while ((getline ml < missing_file) > 0) print ml }
  }
' "$STORY_FILE" > "${TMP}.new"

mv "${TMP}.new" "$STORY_FILE"
log "Review Gate in $STORY_FILE: seeded $missing_count missing rows"
exit 0
