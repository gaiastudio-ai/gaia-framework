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

# git diff --name-only against the base ref. Filter to production paths.
PROD_PATHS="$(git diff --name-only "${BASE_REF}..HEAD" 2>/dev/null \
  | grep -vE '^(gaia-framework/plugins/gaia/tests/|.*/tests/fixtures/|_memory/|docs/|documentation/|\.github/)' \
  | grep -vE '\.bats$' || true)"

if [[ -z "$PROD_PATHS" ]]; then
  log "no production-path changes in $BASE_REF..HEAD — skipping forbidden-sentinel scan"
  exit 0
fi

# --- Load taxonomy and scan ---
GREP_FILE="$("$SCRIPT_DIR/load-taxonomy.sh" --taxonomy forbidden-sentinels --as-grep-file)"
trap 'rm -f "$GREP_FILE"' EXIT

# Scan only ADDED lines in the diff (not the entire working-tree file).
# This prevents false positives from pre-existing sentinel text that the PR
# did not change. The -w (word-boundary) flag is required so a fixed-string
# token only matches as a whole word — without it the token matches as a
# substring and false-positives on mktemp randomization templates (e.g.
# "...XXXXXX").
#
# The diff is parsed with -U0 (zero context) so every hunk line is either a
# removal (-) or an addition (+). Only + lines are scanned. The +N from the
# @@ hunk header tracks the destination line number.
HAS_MATCH=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  # Get the diff for this single file; -U0 suppresses context lines.
  diff_out="$(git diff -U0 "${BASE_REF}..HEAD" -- "$path" 2>/dev/null || true)"
  [[ -n "$diff_out" ]] || continue
  # Parse the diff: extract +N from @@ headers, scan only + lines.
  cur_line=0
  while IFS= read -r dline; do
    # Hunk header: @@ -old[,count] +new[,count] @@
    if [[ "$dline" == "@@"* ]]; then
      # Extract the starting line number after the +
      cur_line="${dline#*+}"       # strip everything up to first +
      cur_line="${cur_line%% *}"   # strip from first space onward
      cur_line="${cur_line%%,*}"   # strip ,count if present
      continue
    fi
    # Skip non-added lines and the +++ header
    [[ "$dline" == "+"* ]] || continue
    [[ "$dline" != "+++"* ]] || continue
    # Strip leading + to get the raw added text
    added_text="${dline#+}"
    match="$(printf '%s' "$added_text" | grep -owFf "$GREP_FILE" 2>/dev/null | head -1 || true)"
    if [[ -n "$match" ]]; then
      printf 'HALT: forbidden sentinel %s in %s:%s — add a Finding row or pass --allow-stub=<reason> to /gaia-dev-story\n' \
        "$match" "$path" "$cur_line" >&2
      HAS_MATCH=1
    fi
    cur_line=$((cur_line + 1))
  done <<<"$diff_out"
done <<<"$PROD_PATHS"

if [[ "$HAS_MATCH" -ne 0 ]]; then
  exit 1
fi

exit 0
