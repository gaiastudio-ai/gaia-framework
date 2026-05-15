#!/usr/bin/env bash
# trace-dispatch-verb-enforcement.sh — /gaia-trace enforcement of
# integration coverage for dispatch-verb medium/high-risk ACs (E88-S6).
#
# Refs:  ADR-107 (taxonomy SSOT via E88-S1), FR-DPD-6, AI-2026-05-13-8,
#        AI-2026-05-13-10.
# Story: E88-S6 (scope-split implementation — AC1 matrix-wide migration
#        deferred to a follow-up).
#
# Purpose
#   For a single story file, walk the ACs and check: for every AC whose
#   body contains a dispatch verb (per E88-S1 taxonomy) AND whose story's
#   `risk:` is `medium` or `high`, verify the traceability matrix has at
#   least one row with `test_class: integration` referencing the story
#   (matched by `<story_key>:<ac_id>` substring or the bare `<story_key>`).
#
# Usage
#   trace-dispatch-verb-enforcement.sh --story-file <path> --matrix-file <path>
#
# Behaviour
#   - exits 0 if all in-scope dispatch-verb ACs have integration coverage,
#     OR if the story has no in-scope ACs (low-risk, or no dispatch verbs).
#   - exits 1 with canonical stderr on a coverage gap:
#       HALT: dispatch-verb AC <story_key>:<ac_id> (risk: <risk>)
#       requires ≥1 integration row in traceability-matrix.md — add a
#       TC-* row with test_class: integration, OR downgrade risk to low.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="trace-dispatch-verb-enforcement.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

STORY_FILE=""
MATRIX_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --story-file)
      [[ $# -ge 2 ]] || die "missing value for --story-file"
      STORY_FILE="$2"
      shift 2
      ;;
    --matrix-file)
      [[ $# -ge 2 ]] || die "missing value for --matrix-file"
      MATRIX_FILE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

[[ -n "$STORY_FILE" ]] || die "missing required flag: --story-file <path>"
[[ -n "$MATRIX_FILE" ]] || die "missing required flag: --matrix-file <path>"
[[ -f "$STORY_FILE" ]] || die "story file not found: $STORY_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./dispatch-verb-match.sh
. "$SCRIPT_DIR/dispatch-verb-match.sh"

# Extract risk and story_key from frontmatter (simple awk pass — no
# heavy dependency on the canonical frontmatter library).
extract_field() {
  local field="$1"
  awk -v key="$field" '
    BEGIN { in_fm = 0; depth = 0 }
    /^---[[:space:]]*$/ {
      depth++
      if (depth == 1) { in_fm = 1; next }
      if (depth == 2) { exit }
    }
    in_fm && $0 ~ "^"key":" {
      sub("^"key":[[:space:]]*", "", $0)
      gsub(/^["'\'']|["'\'']$/, "", $0)
      print
      exit
    }
  ' "$STORY_FILE"
}

RISK="$(extract_field risk)"
STORY_KEY="$(extract_field key)"

# Only enforce for medium/high risk stories.
case "$RISK" in
  medium|high) ;;
  *) exit 0 ;;
esac

[[ -n "$STORY_KEY" ]] || die "could not extract story key from frontmatter: $STORY_FILE"

# Extract AC block. ACs are identified by `**AC<N>` markers (canonical
# create-story shape).
ac_block="$(awk '
  /^## Acceptance Criteria[[:space:]]*$/ { in_block = 1; next }
  in_block && /^## / { in_block = 0 }
  in_block { print }
' "$STORY_FILE")"

[[ -z "$ac_block" ]] && exit 0

# Walk ACs; for each, check dispatch-verb match and integration coverage.
# Track current AC index based on `**AC<N>` markers.
current_ac=""
current_body=""

check_current_ac() {
  [[ -z "$current_ac" ]] && return 0
  [[ -z "$current_body" ]] && return 0
  if ! match_dispatch_verb_in_text "$current_body" >/dev/null 2>&1; then
    return 0
  fi
  # Dispatch-verb AC found in a medium/high-risk story. Check matrix.
  # Match either `<story_key>:<ac_id>` (preferred) or bare `<story_key>` + integration.
  local ref="${STORY_KEY}:${current_ac}"
  if [[ -f "$MATRIX_FILE" ]]; then
    if grep -qE "test_class:[[:space:]]*integration" "$MATRIX_FILE" \
        && grep -F "$ref" "$MATRIX_FILE" \
        | grep -qE "test_class:[[:space:]]*integration"; then
      return 0
    fi
  fi
  printf 'HALT: dispatch-verb AC %s:%s (risk: %s) requires ≥1 integration row in traceability-matrix.md — add a TC-* row with test_class: integration, OR downgrade risk to low.\n' \
    "$STORY_KEY" "$current_ac" "$RISK" >&2
  exit 1
}

while IFS= read -r line; do
  if [[ "$line" =~ ^\*\*AC([0-9]+) ]]; then
    # Boundary: process previous AC then start new.
    check_current_ac
    current_ac="AC${BASH_REMATCH[1]}"
    current_body="$line"
  else
    [[ -n "$current_ac" ]] && current_body+=$'\n'"$line"
  fi
done <<<"$ac_block"

# Process the final AC.
check_current_ac

exit 0
