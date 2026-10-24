#!/usr/bin/env bash
# forbidden-sentinel-scan.sh — /gaia-dev-story Step 11a pre-PR scan.
#
# Purpose
#   Scan the production-path slice of the current branch's diff (vs a base
#   ref) for any forbidden sentinel listed in the taxonomy SSOT at
#   knowledge/taxonomy/forbidden-sentinels.txt. HALT inline with a canonical
#   stderr message on match. Optionally accept an `--allow-stub <reason>`
#   override gated on a story-ID or AI-ID prefix.
#
# Production-path filter (EXEMPT subtrees):
#   - gaia-framework/plugins/gaia/tests/**
#   - **/tests/fixtures/**
#   - _memory/**
#   - docs/**
#   - documentation/**
#   - .github/**
#   - any *.bats file (defense-in-depth)
#
# Usage
#   forbidden-sentinel-scan.sh --base-ref <branch> [--allow-stub <reason>]
#
# Behaviour
#   - exits 0 if no forbidden sentinels in the production-path diff slice
#     (or --allow-stub override is accepted).
#   - exits 1 with canonical stderr `HALT: forbidden sentinel <S> in <path>:<line>
#     — add a Finding row or pass --allow-stub=<reason> to /gaia-dev-story` on
#     a production-path match.
#   - exits 1 with `--allow-stub reason must cite a story ID (Ex-Sx) or AI ID
#     (AI-YYYY-MM-DD-N) — got: <reason>` on a malformed --allow-stub value.
#
# Note: inline HALT (NOT halt-event.sh) — halt-event.sh is
# gaia-meeting-scoped; relocating it to scripts/lib/ is a separate refactor.

set -euo pipefail
LC_ALL=C
export LC_ALL
# Prevent pathspec magic characters (: ! ^) in file paths from being
# interpreted as exclude/glob operators by git diff.
GIT_LITERAL_PATHSPECS=1
export GIT_LITERAL_PATHSPECS

SCRIPT_NAME="forbidden-sentinel-scan.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

BASE_REF=""
ALLOW_STUB=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-ref)
      [[ $# -ge 2 ]] || die "missing value for --base-ref"
      BASE_REF="$2"
      shift 2
      ;;
    --allow-stub)
      [[ $# -ge 2 ]] || die "missing value for --allow-stub"
      ALLOW_STUB="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,35p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

[[ -n "$BASE_REF" ]] || die "missing required flag: --base-ref <branch>"

# --- --allow-stub override (reason regex must cite story-ID or AI-ID) ---
if [[ -n "$ALLOW_STUB" ]]; then
  if printf '%s' "$ALLOW_STUB" | grep -qE '^(E[0-9]+-S[0-9]+|AI-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+):'; then
    # Echo accepted reason on stdout so the caller (SKILL.md Step 11) can
    # forward it to pr-body.sh via --allow-stub-reason.
    printf '%s\n' "$ALLOW_STUB"
    log "scan bypassed via --allow-stub=$ALLOW_STUB"
    exit 0
  fi
  printf -- '--allow-stub reason must cite a story ID (Ex-Sx) or AI ID (AI-YYYY-MM-DD-N) — got: %s\n' \
    "$ALLOW_STUB" >&2
  exit 1
fi

# --- Production-path diff slice ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Suppress colour codes, pager, and external diff drivers — a user's
# color.ui=always / color.diff=always / diff.external must not leak
# ANSI escapes into the output we parse.
# --text forces textual diff even for files marked binary / -diff in
# .gitattributes, so their added lines are scanned rather than silently
# skipped as "Binary files differ".
_git_diff() { git --no-pager diff --no-color --no-ext-diff --no-textconv --text "$@"; }

# git diff --name-only against the base ref. Filter to production paths.
PROD_PATHS="$(_git_diff --name-only "${BASE_REF}..HEAD" 2>/dev/null \
  | grep -vE '^(gaia-framework/plugins/gaia/tests/|.*/tests/fixtures/|_memory/|docs/|documentation/|\.github/)' \
  | grep -vE '\.bats$' || true)"

if [[ -z "$PROD_PATHS" ]]; then
  log "no production-path changes in $BASE_REF..HEAD — skipping forbidden-sentinel scan"
  exit 0
fi

# --- Load taxonomy and scan ---
GREP_FILE="$("$SCRIPT_DIR/load-taxonomy.sh" --taxonomy forbidden-sentinels --as-grep-file)"

# Two parallel temp files: text-only lines for grep, metadata for reporting.
# Grepping the text file (not file:lineno:text) avoids false matches when a
# sentinel word appears in a file path or when colons in paths break parsing.
ADDED_TEXT="$(mktemp "${TMPDIR:-/tmp}/fss-text.XXXXXX")"
ADDED_META="$(mktemp "${TMPDIR:-/tmp}/fss-meta.XXXXXX")"
trap 'rm -f "$GREP_FILE" "$ADDED_TEXT" "$ADDED_META"' EXIT

# Build pathspec array from production paths.
DIFF_PATHS=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  DIFF_PATHS+=("$p")
done <<<"$PROD_PATHS"

# Single-pass scan: one git-diff call, NUL-stripped, piped into awk that
# extracts added lines into a text file and parallel metadata file, then
# one grep pass over the text file.
#
# tr strips NUL bytes that --text exposes from binary files; without it
# GNU grep treats the whole text file as binary and prints nothing.
#
# awk state machine:
#   - "diff --git" resets in_hunk → next +++ is a header, not content.
#   - "+++ b/" (when NOT in a hunk) sets the current file path.
#   - "@@" enters hunk mode and extracts the destination start line.
#   - "+" lines inside a hunk are added content; even lines starting with
#     "++" or "+++" are real content at that point (fixing the earlier
#     false-negative on lines whose text begins with "++").
# The -w (word-boundary) flag on the final grep prevents false positives
# from mktemp randomisation templates (e.g. "...XXXXXX").
_git_diff -U0 "${BASE_REF}..HEAD" -- "${DIFF_PATHS[@]}" 2>/dev/null \
  | tr '\000' ' ' \
  | awk -v metafile="$ADDED_META" '
    /^diff --git /                 { in_hunk = 0; file = ""; next }
    /^\+\+\+ b\// && in_hunk == 0 { file = substr($0, 7); next }
    /^\+\+\+ /    && in_hunk == 0 { file = ""; next }
    /^@@/ {
      in_hunk = 1
      s = $0
      sub(/^@@ [^ ]+ \+/, "", s)
      sub(/[,@ ].*/, "", s)
      cur_line = s + 0
      next
    }
    in_hunk && /^\+/ {
      print substr($0, 2)
      print file "\t" cur_line > metafile
      cur_line++
    }
  ' > "$ADDED_TEXT"

if [[ ! -s "$ADDED_TEXT" ]]; then
  log "no added lines in production-path diff — scan clean"
  exit 0
fi

# Grep the text-only file so sentinels in file paths cannot match.
# -a treats the file as text even if NUL remnants survive (belt-and-braces).
# -n gives the line number in ADDED_TEXT, which maps 1:1 to ADDED_META.
matches="$(grep -anwFf "$GREP_FILE" "$ADDED_TEXT" 2>/dev/null || true)"
if [[ -n "$matches" ]]; then
  # Pre-load metadata into a bash array (one read, no fork per match).
  _META=()
  while IFS= read -r _ml; do _META+=("$_ml"); done < "$ADDED_META"
  while IFS=: read -r grep_lineno text; do
    meta="${_META[$((grep_lineno - 1))]}"
    file="${meta%%	*}"
    lineno="${meta##*	}"
    sentinel="$(printf '%s' "$text" | grep -aowFf "$GREP_FILE" 2>/dev/null | head -1 || true)"
    [[ -n "$sentinel" ]] || continue
    printf 'HALT: forbidden sentinel %s in %s:%s — add a Finding row or pass --allow-stub=<reason> to /gaia-dev-story\n' \
      "$sentinel" "$file" "$lineno" >&2
  done <<<"$matches"
  exit 1
fi

exit 0
