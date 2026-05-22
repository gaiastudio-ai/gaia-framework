#!/usr/bin/env bash
# next-story-id.sh — gaia-create-story Step 4 deterministic next-story-id (E63-S2 / Work Item 6.2)
#
# Purpose:
#   Emit the next available story ID for a given epic by scanning an
#   epics-and-stories.md file. Auto-allocation source consumed by
#   generate-frontmatter.sh (E63-S3) when a story key is not provided
#   explicitly. Sibling deterministic helper to slugify.sh (E63-S1).
#
# Algorithm (in order):
#   1. Parse --epic <key> and --epics-file <path> flags.
#   2. Validate the epics-file exists and is readable.
#   3. Scan the file for anchored matches of <EPIC>-S<N>. The anchoring is
#      load-bearing — a naive substring match would let `E1-S` match inside
#      `E10-S2` and return a wrong next-id once epic numbering exceeds
#      single digits. We use awk with explicit non-alphanumeric boundary
#      character checks instead of grep -P \b (BSD grep on macOS does not
#      universally support PCRE \b).
#   4. Extract numeric suffixes, sort -n, take the max.
#   5. Default max to 0 when zero matches (empty-epic case).
#   6. Emit <EPIC>-S<max+1> on stdout.
#
# Exit codes:
#   0 — success
#   1 — missing/unreadable --epics-file
#   2 — usage error (missing flag, unknown flag)
#
# Locale invariance:
#   `LC_ALL=C` is set so awk pattern matching, sort -n ordering, and grep
#   character classes behave identically on macOS BSD and Linux GNU.
#
# Spec references:
#   - .gaia/artifacts/planning-artifacts/feature-create-story-hardening.md#Work-Item-6.2
#   - .gaia/artifacts/planning-artifacts/architecture.md §Decision Log — ADR-074
#   - gaia-public/plugins/gaia/skills/gaia-shell-idioms/SKILL.md
#   - Sibling: gaia-public/plugins/gaia/skills/gaia-create-story/scripts/slugify.sh

set -euo pipefail
LC_ALL=C
export LC_ALL

usage() {
  cat >&2 <<'USAGE'
Usage: next-story-id.sh --epic <EPIC> --epics-file <path>

  --epic <EPIC>          Epic key (e.g., E1, E63). Required.
  --epics-file <path>    Path to epics-and-stories.md. Required.

Emits <EPIC>-S<N+1> where N is the maximum existing story suffix for
<EPIC> in the epics-file. When zero matches exist, emits <EPIC>-S1.
USAGE
}

epic=""
epics_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --epic)
      if [ $# -lt 2 ]; then
        printf 'next-story-id.sh: --epic requires a value\n' >&2
        exit 2
      fi
      epic="$2"
      shift 2
      ;;
    --epics-file)
      if [ $# -lt 2 ]; then
        printf 'next-story-id.sh: --epics-file requires a value\n' >&2
        exit 2
      fi
      epics_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'next-story-id.sh: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$epic" ]; then
  printf 'next-story-id.sh: --epic is required\n' >&2
  usage
  exit 2
fi

if [ -z "$epics_file" ]; then
  printf 'next-story-id.sh: --epics-file is required\n' >&2
  usage
  exit 2
fi

if [ ! -r "$epics_file" ]; then
  printf 'next-story-id.sh: epics-file not found: %s\n' "$epics_file" >&2
  exit 1
fi

# Anchored scan via awk. The pattern requires the match to be preceded by
# either start-of-line or a non-alphanumeric character, and followed by a
# digit-then-non-digit boundary. This rules out E1 matching inside E10.
# We extract every numeric suffix, one per line, then sort -n + tail -1.
max="$(awk -v epic="$epic" '
  {
    line = $0
    while (match(line, "(^|[^A-Za-z0-9])" epic "-S[0-9]+")) {
      seg = substr(line, RSTART, RLENGTH)
      # Strip any leading non-alnum byte captured by the boundary group.
      sub("^[^A-Za-z0-9]", "", seg)
      sub("^" epic "-S", "", seg)
      print seg
      line = substr(line, RSTART + RLENGTH)
    }
  }
' "$epics_file" | sort -n | tail -1)"

max="${max:-0}"
next=$((max + 1))
printf '%s-S%d\n' "$epic" "$next"
