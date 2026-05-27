#!/usr/bin/env bash
# resolve-review-report-path.sh — single-source resolver for review-report write
# paths (E105-S4 / ADR-127 §7.4 / Test05 F-046).
#
# The gaia-run-all-reviews canonical table is the source of the BASENAME for each
# review type (FR-402 type-first: code-review-{key}.md, qa-tests-{key}.md, etc.).
# This helper resolves the DIRECTORY the report should be written to, so all six
# review skills + review-summary-gen.sh agree without re-implementing path logic:
#
#   - NEW canonical home (E105-S1 layout): the per-story `reviews/` subdir
#     `${IMPL}/epic-{slug}/{key}-{slug}/reviews/<basename>` when the story lives
#     in the new per-story layout (resolved via resolve-story-file.sh: a
#     story.md whose parent dir carries the key). The reviews/ dir is created.
#   - Legacy fallback: the flat `${IMPL}/<basename>` (read-compat during the
#     migration window; also the target when the story is still flat/legacy-nested).
#
# Resolution is deterministic and side-effect-light: it only `mkdir -p`s the
# per-story reviews/ dir on the NEW-layout path (so the caller can write there).
#
# Usage:
#   resolve-review-report-path.sh --key <story_key> --type <review-type>
#   resolve-review-report-path.sh --help
#
# <review-type> is the FR-402 type-first basename stem, e.g.:
#   code-review | qa-tests | security-review | test-automate-review |
#   test-review | performance-review
# The basename written is "<review-type>-<key>.md".
#
# Stdout: the absolute-or-relative report path to write.
# Exit codes: 0 ok; 1 usage/arg error.

set -euo pipefail
SCRIPT_NAME="resolve-review-report-path.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { err "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
resolve-review-report-path.sh — resolve a review report's write path

Usage: resolve-review-report-path.sh --key <story_key> --type <review-type>

Prints the per-story reviews/ path (E105-S1 layout) when the story is in the new
layout, else the flat implementation-artifacts/ path. Creates the per-story
reviews/ dir on the new-layout path. <review-type> is the FR-402 stem, e.g.
code-review; the basename is "<type>-<key>.md".
USAGE
  exit 0
fi

KEY="" RTYPE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key)  [ $# -ge 2 ] || die "--key requires a value";  KEY="$2";  shift 2 ;;
    --type) [ $# -ge 2 ] || die "--type requires a value"; RTYPE="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$KEY" ]   || die "usage: --key <story_key> --type <review-type>"
[ -n "$RTYPE" ] || die "usage: --key <story_key> --type <review-type>"

# Resolve the implementation-artifacts root (mirrors resolve-story-file.sh).
if [ -n "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
  IMPL="$IMPLEMENTATION_ARTIFACTS"
elif [ -d ".gaia/artifacts/implementation-artifacts" ]; then
  IMPL=".gaia/artifacts/implementation-artifacts"
else
  IMPL="docs/implementation-artifacts"
fi

basename_out="${RTYPE}-${KEY}.md"
flat_path="${IMPL}/${basename_out}"

# Try to resolve the story file; if it is in the NEW per-story layout
# (basename story.md, parent dir carries the key, no /stories/ segment), the
# canonical reviews/ home is the sibling reviews/ dir.
RESOLVER="$SCRIPT_DIR/resolve-story-file.sh"
story_file=""
if [ -x "$RESOLVER" ]; then
  story_file="$("$RESOLVER" "$KEY" 2>/dev/null || true)"
fi

if [ -n "$story_file" ]; then
  case "$story_file" in
    */stories/*) : ;;                     # legacy nested → flat fallback
    */story.md)
      story_dir="$(dirname "$story_file")"
      reviews_dir="${story_dir}/reviews"
      mkdir -p "$reviews_dir" 2>/dev/null || true
      if [ -d "$reviews_dir" ]; then
        printf '%s/%s\n' "$reviews_dir" "$basename_out"
        exit 0
      fi
      ;;
  esac
fi

# Fallback: flat implementation-artifacts path (legacy / migration window).
printf '%s\n' "$flat_path"
