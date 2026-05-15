#!/usr/bin/env bash
# intake-dispatch-verb-check.sh — Intake-time dispatch-verb enforcement (E88-S2).
#
# Refs:  ADR-107 (closed-list taxonomies SSOT), FR-DPD-2, AI-2026-05-13-4.
# Story: E88-S2.
#
# Purpose
#   Enforce at intake time (when a story file is being elaborated by
#   `/gaia-create-story` or `/gaia-add-feature`) that any acceptance
#   criterion mentioning a dispatch verb (per the E88-S1 taxonomy SSOT at
#   knowledge/taxonomy/dispatch-verbs.txt) is paired with a companion
#   integration-test AC OR explicitly annotated with the override comment
#   `<!-- gaia:contract-only: <reason> -->`.
#
# Usage
#   intake-dispatch-verb-check.sh --story-file <path>
#
# Exit codes
#   0 — no enforcement violation; story is intake-compliant. If any AC
#       carried a contract-only override, the helper appended a
#       `**Contract-only ACs:**` subsection to the story Dev Notes
#       capturing the reason(s).
#   1 — HALT. At least one dispatch-verb AC lacks a companion
#       integration-test AC and has no contract-only override. The
#       canonical stderr message names the offending AC index and excerpt.
#
# Canonical HALT message (do NOT paraphrase — downstream consumers
# pattern-match a constant prefix):
#   HALT: dispatch-verb AC #<n> ("<excerpt>") lacks a companion
#   integration-test AC. Add an integration-test AC, OR annotate this AC
#   with <!-- gaia:contract-only: <reason> --> if the dispatch is contract-only.
#
# Implementation notes
#   - Sources `lib/dispatch-verb-match.sh` for the matcher function so the
#     closed-list taxonomy stays SSOT (ADR-107 contract).
#   - AC extraction is shape-tolerant: ACs are scanned between the
#     `## Acceptance Criteria` header and the next `## ` heading. Within
#     that block, ACs are identified by lines starting with either
#     `**AC<N>` (the canonical create-story shape) or `- [ ]` / `- AC<N>`
#     (alternative shapes). One AC body per match — adjacent prose lines
#     up to the next AC marker are treated as part of the current AC.
#   - Integration-test heuristic: case-insensitive regex
#       \b(bats\s+integration\s+test|integration\s+test|integration[^a-z]+tests:)\b
#     applied to the concatenated AC bodies. A single match anywhere
#     means the story has integration-test coverage.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="intake-dispatch-verb-check.sh"
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
      sed -n '1,42p' "$0" | sed 's/^# \{0,1\}//'
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
# shellcheck source=./dispatch-verb-match.sh
. "$SCRIPT_DIR/dispatch-verb-match.sh"

# Extract the AC block between `## Acceptance Criteria` and the next
# `## ` heading. Returns the block on stdout.
extract_ac_block() {
  awk '
    /^## Acceptance Criteria[[:space:]]*$/ { in_block = 1; next }
    in_block && /^## / { in_block = 0 }
    in_block { print }
  ' "$STORY_FILE"
}

AC_BLOCK="$(extract_ac_block)"
if [[ -z "$AC_BLOCK" ]]; then
  # No AC section at all — nothing to enforce. Caller should validate the
  # presence of an AC section separately (validate-frontmatter / template).
  exit 0
fi

# Split AC_BLOCK into a list of AC bodies. An AC starts on a line matching
# either `**AC<N>` (canonical) or `- [ ]` / `- AC<N>` (alternative). Each
# subsequent non-marker line until the next marker (or end of block) is
# appended to the current AC's body.
SPLIT_ACS_FILE="$(mktemp "${TMPDIR:-/tmp}/intake-acs.XXXXXX")"
trap 'rm -f "$SPLIT_ACS_FILE"' EXIT

printf '%s\n' "$AC_BLOCK" | awk '
  BEGIN { idx = 0; body = "" }
  function flush(    out) {
    if (idx > 0 && length(body) > 0) {
      gsub(/\n/, "\\n", body)
      printf "%d\t%s\n", idx, body
    }
  }
  /^[[:space:]]*\*\*AC[0-9]+/ || /^[[:space:]]*- \[[ x]\] AC[0-9]+/ || /^[[:space:]]*- AC[0-9]+/ {
    flush()
    idx++
    body = $0
    next
  }
  {
    if (idx > 0) {
      body = body "\n" $0
    }
  }
  END { flush() }
' > "$SPLIT_ACS_FILE"

# Build a master AC text for the integration-test heuristic, and detect
# whether any AC overall mentions integration testing.
ALL_AC_TEXT="$(awk -F'\t' '{ gsub(/\\n/, "\n", $2); print $2 }' "$SPLIT_ACS_FILE")"

has_integration_test_ac() {
  # Case-insensitive search for any of:
  #   "bats integration test", "integration test", "integration<sep>tests:"
  printf '%s\n' "$ALL_AC_TEXT" \
    | grep -qiE '\b(bats[[:space:]]+integration[[:space:]]+test|integration[[:space:]]+test|integration[^a-z]+tests:)\b'
}

# Walk each AC; flag dispatch-verb ACs without integration coverage and
# without a contract-only override. Collect contract-only reasons for the
# Dev-Notes injection.
CONTRACT_ONLY_REASONS_FILE="$(mktemp "${TMPDIR:-/tmp}/contract-only.XXXXXX")"
trap 'rm -f "$SPLIT_ACS_FILE" "$CONTRACT_ONLY_REASONS_FILE"' EXIT

HAS_INTEGRATION=0
if has_integration_test_ac; then
  HAS_INTEGRATION=1
fi

while IFS=$'\t' read -r ac_idx ac_body; do
  [[ -z "$ac_idx" ]] && continue
  # Unescape newlines.
  ac_body="$(printf '%s' "$ac_body" | sed 's/\\n/\n/g')"

  # Contract-only override?
  if printf '%s' "$ac_body" | grep -qF '<!-- gaia:contract-only:'; then
    reason="$(printf '%s' "$ac_body" \
      | sed -n 's/.*<!-- gaia:contract-only:[[:space:]]*\(.*\)[[:space:]]*-->.*/\1/p' \
      | head -n1)"
    printf '%s\t%s\n' "$ac_idx" "$reason" >> "$CONTRACT_ONLY_REASONS_FILE"
    continue
  fi

  # Dispatch-verb present?
  if match_dispatch_verb_in_text "$ac_body" >/dev/null 2>&1; then
    if [[ "$HAS_INTEGRATION" -eq 0 ]]; then
      # Build a short excerpt of the AC body (first 80 chars of first non-empty line).
      excerpt="$(printf '%s' "$ac_body" \
        | tr '\n' ' ' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]\{2,\}/ /g' \
        | cut -c1-80)"
      printf 'HALT: dispatch-verb AC #%s ("%s") lacks a companion integration-test AC. Add an integration-test AC, OR annotate this AC with <!-- gaia:contract-only: <reason> --> if the dispatch is contract-only.\n' \
        "$ac_idx" "$excerpt" >&2
      exit 1
    fi
  fi
done < "$SPLIT_ACS_FILE"

# Inject `**Contract-only ACs:**` subsection into Dev Notes when overrides
# were observed. Append to existing Dev Notes if present; create section if absent.
if [[ -s "$CONTRACT_ONLY_REASONS_FILE" ]]; then
  NOTES_BLOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/notes-block.XXXXXX")"
  trap 'rm -f "$SPLIT_ACS_FILE" "$CONTRACT_ONLY_REASONS_FILE" "$NOTES_BLOCK_FILE"' EXIT
  {
    printf '**Contract-only ACs:**\n\n'
    while IFS=$'\t' read -r ac_idx reason; do
      printf -- '- AC #%s: %s\n' "$ac_idx" "$reason"
    done < "$CONTRACT_ONLY_REASONS_FILE"
    printf '\n'
  } > "$NOTES_BLOCK_FILE"

  if grep -qE '^## Dev Notes[[:space:]]*$' "$STORY_FILE"; then
    # Append to existing Dev Notes section (insert just after the heading +
    # blank line). Read the block from file to avoid awk newline-in-string
    # restrictions.
    awk -v block_file="$NOTES_BLOCK_FILE" '
      BEGIN {
        block = ""
        while ((getline line < block_file) > 0) block = block line "\n"
        close(block_file)
      }
      /^## Dev Notes[[:space:]]*$/ && !injected {
        print
        print ""
        printf "%s", block
        injected = 1
        next
      }
      { print }
    ' "$STORY_FILE" > "$STORY_FILE.tmp" && mv "$STORY_FILE.tmp" "$STORY_FILE"
  else
    # No Dev Notes section: append one at the end.
    {
      printf '\n## Dev Notes\n\n'
      cat "$NOTES_BLOCK_FILE"
    } >> "$STORY_FILE"
  fi
fi

exit 0
