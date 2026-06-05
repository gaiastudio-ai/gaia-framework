#!/usr/bin/env bash
# classify-files.sh — deterministic performance-relevance classifier
#
# Classifies a list of changed files as performance-relevant or not.
# Performance-relevant: source code files that can contain DB queries, API
# endpoints, rendering logic, loops, caching, network calls.
# Not relevant: documentation, config, tests, static assets, CSS-only, lock
# files.
#
# Implements the auto-pass fast path for the gaia-performance-review anytime
# skill. When zero performance-relevant files are present, emits
# "PASSED (auto)" and exits 0 so the skill can short-circuit to verdict
# without running full bottleneck analysis.
#
# Usage:
#   classify-files.sh --file-list <file>          # read newline-separated list
#   classify-files.sh --files file1 file2 ...     # read files as args
#   echo "f1\nf2" | classify-files.sh --stdin     # read from stdin
#
# Output:
#   Line 1: "PASSED (auto)" if zero perf-relevant files, else "REVIEW"
#   Followed by: classification table with columns PATH | RELEVANCE
#
# Exit codes:
#   0 — classification complete (regardless of verdict)
#   1 — usage error

set -euo pipefail
LC_ALL=C
export LC_ALL

usage() {
  cat >&2 <<EOF
Usage:
  classify-files.sh --file-list <path-to-newline-list>
  classify-files.sh --files <file1> [<file2> ...]
  classify-files.sh --stdin
EOF
  exit 1
}

# Performance-relevant extensions (application source code)
PERF_RELEVANT_EXTS=".ts .tsx .js .jsx .mjs .cjs .py .java .go .rb .php .dart .swift .kt .kts .rs .cs .cpp .cc .c .h .hpp .sql"

# Not-relevant extensions and patterns (docs, config, tests, assets)
NOT_RELEVANT_EXTS=".md .rst .txt .yml .yaml .json .toml .ini .xml .html .css .scss .sass .less .gitignore .gitattributes .editorconfig .svg .png .jpg .jpeg .gif .webp .ico .lock .lock.json"

# Test file patterns (should be classified as not-relevant for perf review auto-pass)
TEST_PATTERNS="\.test\.|\.spec\.|/__tests__/|/tests?/|_test\.|\.bats$"

is_perf_relevant() {
  local path="$1"
  local base="${path##*/}"
  local ext=".${base##*.}"
  # Lowercase for matching
  ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')

  # Exclude test files regardless of extension
  if printf '%s' "$path" | grep -qiE "$TEST_PATTERNS"; then
    return 1
  fi

  # Exclude lock files (package-lock.json, yarn.lock, etc.) — check by base name
  case "$base" in
    *-lock.json|*.lock|*.lockb|yarn.lock|pnpm-lock.yaml|Gemfile.lock|Pipfile.lock|Cargo.lock|go.sum|composer.lock)
      return 1
      ;;
  esac

  # Performance-relevant source code
  for pr in $PERF_RELEVANT_EXTS; do
    if [ "$ext" = "$pr" ]; then
      return 0
    fi
  done

  return 1
}

# ---------- Parse args ----------
FILES=()
MODE=""
case "${1:-}" in
  --file-list)
    shift || true
    [ -n "${1:-}" ] || usage
    [ -r "$1" ] || { printf 'classify-files.sh: file-list not readable: %s\n' "$1" >&2; exit 1; }
    MODE="list"
    while IFS= read -r line; do
      [ -n "$line" ] && FILES+=("$line")
    done < "$1"
    ;;
  --files)
    shift || true
    MODE="args"
    while [ $# -gt 0 ]; do
      FILES+=("$1")
      shift
    done
    ;;
  --stdin)
    MODE="stdin"
    while IFS= read -r line; do
      [ -n "$line" ] && FILES+=("$line")
    done
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage
    ;;
esac

# ---------- Classify ----------
RELEVANT_COUNT=0
TOTAL=${#FILES[@]}
CLASSIFICATIONS=()

for f in "${FILES[@]}"; do
  if is_perf_relevant "$f"; then
    CLASSIFICATIONS+=("$f|relevant")
    RELEVANT_COUNT=$((RELEVANT_COUNT + 1))
  else
    CLASSIFICATIONS+=("$f|not-relevant")
  fi
done

# ---------- Emit verdict + table ----------
if [ "$RELEVANT_COUNT" -eq 0 ]; then
  printf 'PASSED (auto)\n'
  printf 'No performance-relevant code changes — auto-passed.\n'
else
  printf 'REVIEW\n'
  printf '%d of %d files require full performance analysis.\n' "$RELEVANT_COUNT" "$TOTAL"
fi
printf '\n'
printf 'PATH|RELEVANCE\n'
for entry in "${CLASSIFICATIONS[@]}"; do
  printf '%s\n' "$entry"
done

exit 0
