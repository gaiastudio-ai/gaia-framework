#!/usr/bin/env bash
# completion-notes-deferral-scan.sh — Scan a story file's
# `### Completion Notes List` for deferral phrases (per the E88-S1 taxonomy
# SSOT) and pair-check each match against the story's `## Findings` table
# (E88-S4, FR-DPD-4, ADR-107).
#
# Refs:  ADR-107 (closed-list taxonomies SSOT), FR-DPD-4, AI-2026-05-13-6.
# Story: E88-S4.
#
# Consumers
#   - The Val `completion-notes-deferral-scan` pattern (gaia-validation-patterns).
#   - `/gaia-triage-findings` Step 1b extended scanner.
#
# Usage
#   completion-notes-deferral-scan.sh --story-file <path>
#
# Output (stdout, one record per matched phrase)
#   phrase=<phrase>\tpaired=<true|false>\tfinding_id=<id-or-empty>
#
#   - `paired=true` when the phrase appears as a substring in the Finding
#     column of a `## Findings` row OR the Completion-Notes line that
#     surfaced it carries an explicit `Finding ID: <X>` token.
#   - `paired=false` when neither pair-check matched (drift candidate).
#
# Exit codes
#   0 — helper completed (regardless of pair-check verdict). Empty stdout
#       means no deferral phrases were matched in Completion Notes.
#   1 — usage error (missing flag, missing file).
#
# The helper sources `lib/deferral-phrase-match.sh` (E88-S1) — it MUST NOT
# inline the taxonomy. ADR-107 SSOT.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="completion-notes-deferral-scan.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

STORY_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --story-file)
      [[ $# -ge 2 ]] || die "missing value for --story-file"
      STORY_FILE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

[[ -n "$STORY_FILE" ]] || die "missing required flag: --story-file <path>"
[[ -f "$STORY_FILE" ]] || die "story file not found: $STORY_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./deferral-phrase-match.sh
. "$SCRIPT_DIR/deferral-phrase-match.sh"

# Extract the `### Completion Notes List` subsection. Block runs from the
# heading to the next `## ` or `### ` heading.
extract_completion_notes() {
  awk '
    /^### Completion Notes List[[:space:]]*$/ { in_block = 1; next }
    in_block && (/^## / || /^### /) { in_block = 0 }
    in_block { print }
  ' "$STORY_FILE"
}

# Extract the `## Findings` table body (everything after the heading until
# the next `## ` heading). Returns table rows (Markdown pipe lines).
extract_findings_table() {
  awk '
    /^## Findings[[:space:]]*$/ { in_block = 1; next }
    in_block && /^## / { in_block = 0 }
    in_block && /^\|/ { print }
  ' "$STORY_FILE"
}

NOTES="$(extract_completion_notes)"
if [[ -z "$NOTES" ]]; then
  exit 0
fi

FINDINGS_TABLE="$(extract_findings_table)"

# For each Completion-Notes line, match deferral phrases; pair-check; emit.
# Process the section line-by-line so we can attach per-line context to
# each match (the `Finding ID: <X>` token is per-line).
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  matches="$(match_deferral_phrase_in_text "$line" || true)"
  [[ -z "$matches" ]] && continue

  # Inline Finding-ID token (if any) on this Completion-Notes line.
  inline_fid="$(printf '%s' "$line" | sed -n 's/.*Finding ID:[[:space:]]*\([A-Za-z0-9_-]\+\).*/\1/p' | head -n1)"

  while IFS= read -r phrase; do
    [[ -z "$phrase" ]] && continue
    paired="false"
    matched_fid=""

    # Pair-check 1: explicit `Finding ID:` token on the same line.
    if [[ -n "$inline_fid" ]]; then
      paired="true"
      matched_fid="$inline_fid"
    fi

    # Pair-check 2: substring match against the Findings table.
    if [[ "$paired" = "false" ]] && [[ -n "$FINDINGS_TABLE" ]]; then
      # Look for the phrase as a substring in any non-separator row.
      if printf '%s' "$FINDINGS_TABLE" | grep -vE '^\|[[:space:]]*-' | grep -qF "$phrase"; then
        paired="true"
        # Best-effort: pull the row's first column as Finding ID.
        matched_fid="$(printf '%s' "$FINDINGS_TABLE" \
          | grep -F "$phrase" \
          | grep -vE '^\|[[:space:]]*-' \
          | head -n1 \
          | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')"
      fi
    fi

    printf 'phrase=%s\tpaired=%s\tfinding_id=%s\n' "$phrase" "$paired" "$matched_fid"
  done <<<"$matches"
done <<<"$NOTES"

exit 0
