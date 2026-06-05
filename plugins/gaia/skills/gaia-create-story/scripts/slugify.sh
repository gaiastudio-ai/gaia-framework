#!/usr/bin/env bash
# slugify.sh — gaia-create-story deterministic slug generator
#
# Purpose:
#   Convert a story title into a byte-deterministic filename slug. This script
#   is the dependency root for the script tier — generate-frontmatter.sh,
#   validate-canonical-filename.sh, and scaffold-story.sh all consume the
#   contract produced here.
#
# Algorithm (in order):
#   1. Read input from --title <string> or stdin (first one wins).
#   2. Lowercase the result (LC_ALL=C makes this a byte-level A-Z -> a-z).
#   3. Replace any non-alphanumeric byte with a single `-`. Under LC_ALL=C
#      the `[:alnum:]` class is the ASCII alnum set, so every non-ASCII byte
#      (e.g. the two-byte UTF-8 sequence for `é`, 0xC3 0xA9) is non-alnum
#      and is converted to `-`. THIS IS THE DELIBERATE DETERMINISM POLICY —
#      non-ASCII bytes become hyphens; they are NOT transliterated. A multi-
#      byte character therefore yields multiple consecutive hyphens which
#      step 4 collapses. If the team later prefers transliteration via
#      `iconv -f UTF-8 -t ASCII//TRANSLIT`, document the deviation in this
#      header and update the validation fixtures in lockstep.
#   4. Collapse runs of `-` to a single `-`.
#   5. Trim a leading or trailing `-`.
#
# Empty-input contract:
#   Both an empty title and an all-non-alphanumeric title yield empty stdout
#   with exit code 0. Callers that need a non-empty slug must validate
#   upstream — this script does not police caller intent.
#
# Exit codes:
#   0 — success (including empty output)
#   non-zero — bash error only (e.g. unexpected flag)
#
# Locale invariance:
#   `LC_ALL=C` is set so character-class semantics in `tr` are byte-based and
#   identical across macOS, Linux, and CI runners.
#
# Spec references:
#   - .gaia/artifacts/planning-artifacts/feature-create-story-hardening.md#Work-Item-6.3
#   - .gaia/artifacts/planning-artifacts/architecture.md §Decision Log
#   - gaia-framework/plugins/gaia/skills/gaia-shell-idioms/SKILL.md (set -euo
#     pipefail + LC_ALL=C + tr|sed collapse-and-trim)

set -euo pipefail
LC_ALL=C
export LC_ALL

# Usage block. Emitted to stdout for --help / -h so the block can be piped
# to `grep`, `less`, etc. without merging stderr. Sibling scripts
# (next-story-id.sh, generate-frontmatter.sh) emit Usage to stderr;
# slugify.sh deliberately uses stdout because the script's primary stdout
# payload (the slug) is never produced when --help is the dispatch, so
# there is no stream collision.
usage() {
  cat <<'USAGE'
Usage: slugify.sh --title <s>
       slugify.sh --help | -h

Convert a story title into a byte-deterministic filename slug. The slug is
lowercased, non-alphanumeric bytes are replaced with `-`, runs of `-` are
collapsed, and a leading or trailing `-` is trimmed. Non-ASCII bytes are
dropped (deterministic policy — they are NOT transliterated).

Options:
  --title <s>    Title to slugify. If omitted, the first line of stdin is
                 used instead.
  --help, -h     Print this help block to stdout and exit 0.

Exit codes:
  0    success (including empty output for empty/all-non-alphanumeric input)
  2    usage error (unknown flag, --title without a value)
USAGE
}

# Argument parsing — only --title is supported, plus stdin fallback. We use a
# simple `case` (not `getopts`) per the story Technical Notes.
title=""
title_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --title)
      if [ $# -lt 2 ]; then
        printf 'slugify.sh: --title requires a value\n' >&2
        exit 2
      fi
      title="$2"
      title_set=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'slugify.sh: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

# If --title was not provided, read from stdin. We keep only the first line so
# multi-line stdin (e.g. `cat file | slugify.sh`) collapses predictably.
if [ "$title_set" -eq 0 ]; then
  IFS= read -r title || title=""
fi

# Pipeline: lowercase -> non-alnum -> collapse -> trim. Under LC_ALL=C the
# `[:alnum:]` class is byte-level ASCII alnum, so every non-ASCII byte (the
# bytes of any multi-byte UTF-8 character) is non-alnum and becomes `-`.
# For example: `café résumé` -> `caf-r-sum`.
slug="$(printf '%s' "$title" \
  | tr 'A-Z' 'a-z' \
  | tr -c '[:alnum:]' '-' \
  | tr -s '-' \
  | sed 's/^-//; s/-$//')"

printf '%s\n' "$slug"
