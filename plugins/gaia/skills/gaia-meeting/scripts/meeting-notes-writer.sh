#!/usr/bin/env bash
# meeting-notes-writer.sh — gaia-meeting saved-notes writer (E76-S3)
#
# AC9 / FR-MTG-27
#
# Reads a payload YAML describing the closed meeting (charter, mode, attendees
# with per-attendee token costs, total tokens, transcript, summary, preludes,
# decisions, risks, open questions, scratchpad final state, action-item IDs,
# memory write-through agent list) and renders the canonical saved-notes file
# at:
#   <root>/docs/creative-artifacts/meeting-<YYYY-MM-DD>-<slug>.md
#
# Frontmatter contract:
#   - per-attendee + total token-cost breakdown
#   - scratchpad_extractions: []  (empty when E76-S4 not yet landed)
#   - action_items: [AI-..., AI-...]  (IDs from the action-items writer)
#
# Body contract — required H2 sections in order:
#   ## Charter
#   ## Summary
#   ## Research preludes
#   ## Transcript
#   ## Decisions
#   ## Risks identified
#   ## Open questions
#   ## Scratchpad final state
#   ## Action items
#   ## Memory write-through
#
# Atomic write: tempfile + mv.
#
# Usage:
#   meeting-notes-writer.sh \
#     --root <project-root> \
#     --payload <path-to-payload.yaml> \
#     --date <YYYY-MM-DD> \
#     --slug <slug>
#
# Exit codes:
#   0 = success
#   2 = invalid args
#   3 = I/O error

set -euo pipefail

ROOT=""
PAYLOAD=""
DATE=""
SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)    ROOT="$2"; shift 2 ;;
    --payload) PAYLOAD="$2"; shift 2 ;;
    --date)    DATE="$2"; shift 2 ;;
    --slug)    SLUG="$2"; shift 2 ;;
    *) echo "meeting-notes-writer.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ROOT" || -z "$PAYLOAD" || -z "$DATE" || -z "$SLUG" ]]; then
  echo "meeting-notes-writer.sh: --root, --payload, --date, --slug required" >&2
  exit 2
fi

if [[ ! -f "$PAYLOAD" ]]; then
  echo "meeting-notes-writer.sh: payload file not found: $PAYLOAD" >&2
  exit 3
fi

# --- tiny YAML extractors (no yq dependency) ---

_scalar() {
  local file="$1" key="$2"
  awk -v k="$key" '
    $0 ~ ("^" k ":[[:space:]]*") {
      sub("^" k ":[[:space:]]*", "")
      sub(/^"/, ""); sub(/"$/, "")
      print
      exit
    }
  ' "$file"
}

_block_scalar() {
  # Read a `key: |` block scalar.
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_block=0; indent="" }
    $0 ~ ("^" k ":[[:space:]]*\\|[[:space:]]*$") { in_block=1; next }
    in_block {
      if (indent == "" && /^[[:space:]]/) {
        match($0, /^[[:space:]]+/)
        indent = substr($0, 1, RLENGTH)
      }
      if (indent != "" && index($0, indent) == 1) {
        print substr($0, length(indent)+1)
        next
      } else if ($0 == "") {
        print ""
        next
      } else {
        in_block=0
      }
    }
  ' "$file"
}

_list() {
  # Extract a top-level YAML list (`- "..."` items) under key.
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_block = 0 }
    $0 ~ ("^" k ":[[:space:]]*$") { in_block = 1; next }
    in_block && /^[A-Za-z_][A-Za-z0-9_]*:/ { in_block = 0 }
    in_block && /^[[:space:]]+-[[:space:]]+/ {
      sub(/^[[:space:]]+-[[:space:]]+/, "")
      gsub(/^"/, "")
      gsub(/"$/, "")
      print
    }
  ' "$file"
}

_attendees_block() {
  # Extract attendees mapping list — each block has `- name: x` then indented fields.
  local file="$1"
  awk '
    BEGIN { in_block = 0 }
    /^attendees:[[:space:]]*$/ { in_block = 1; next }
    in_block && /^[A-Za-z_][A-Za-z0-9_]*:/ { in_block = 0 }
    in_block { print }
  ' "$file"
}

CHARTER="$(_scalar "$PAYLOAD" charter)"
MODE="$(_scalar "$PAYLOAD" mode)"
TOTAL_TOKENS="$(_scalar "$PAYLOAD" total_tokens)"
SUMMARY="$(_scalar "$PAYLOAD" summary)"
SCRATCHPAD_FINAL="$(_scalar "$PAYLOAD" scratchpad_final)"

TRANSCRIPT="$(_block_scalar "$PAYLOAD" transcript)"
PRELUDES="$(_block_scalar "$PAYLOAD" preludes)"

ATTENDEES="$(_attendees_block "$PAYLOAD")"

DECISIONS_LIST="$(_list "$PAYLOAD" decisions)"
RISKS_LIST="$(_list "$PAYLOAD" risks)"
OPEN_Q_LIST="$(_list "$PAYLOAD" open_questions)"
ACTION_IDS_LIST="$(_list "$PAYLOAD" action_items)"
MEM_WT_LIST="$(_list "$PAYLOAD" memory_writethrough)"

# Compose action_items inline-list for frontmatter
action_items_inline="["
first=1
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  if [[ $first -eq 1 ]]; then
    action_items_inline+="${id}"
    first=0
  else
    action_items_inline+=", ${id}"
  fi
done <<< "$ACTION_IDS_LIST"
action_items_inline+="]"

out_dir="$ROOT/docs/creative-artifacts"
out="$out_dir/meeting-${DATE}-${SLUG}.md"
mkdir -p "$out_dir"

tmp="$(mktemp)"

{
  echo "---"
  echo "date: ${DATE}"
  echo "slug: ${SLUG}"
  echo "charter: \"${CHARTER}\""
  echo "mode: ${MODE}"
  echo "cost_breakdown:"
  if [[ -n "$ATTENDEES" ]]; then
    # Re-emit the attendees mapping list with stable indentation.
    echo "$ATTENDEES" | sed -E 's/^[[:space:]]+/  /'
  fi
  echo "total_tokens: ${TOTAL_TOKENS}"
  echo "scratchpad_extractions: []"
  echo "action_items: ${action_items_inline}"
  echo "---"
  echo ""

  echo "## Charter"
  echo ""
  echo "${CHARTER}"
  echo ""

  echo "## Summary"
  echo ""
  echo "${SUMMARY}"
  echo ""

  echo "## Research preludes"
  echo ""
  echo "${PRELUDES}"
  echo ""

  echo "## Transcript"
  echo ""
  echo "${TRANSCRIPT}"
  echo ""

  echo "## Decisions"
  echo ""
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    echo "- ${d}"
  done <<< "$DECISIONS_LIST"
  echo ""

  echo "## Risks identified"
  echo ""
  echo "_(Sourced from \`[challenge]\` turns in the transcript.)_"
  echo ""
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    echo "- ${r}"
  done <<< "$RISKS_LIST"
  echo ""

  echo "## Open questions"
  echo ""
  while IFS= read -r q; do
    [[ -z "$q" ]] && continue
    echo "- ${q}"
  done <<< "$OPEN_Q_LIST"
  echo ""

  echo "## Scratchpad final state"
  echo ""
  if [[ -n "$SCRATCHPAD_FINAL" ]]; then
    echo "${SCRATCHPAD_FINAL}"
  else
    echo "_(empty — no scratchpad pinned in this meeting)_"
  fi
  echo ""

  echo "## Action items"
  echo ""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    echo "- ${id}"
  done <<< "$ACTION_IDS_LIST"
  echo ""

  echo "## Memory write-through"
  echo ""
  while IFS= read -r ag; do
    [[ -z "$ag" ]] && continue
    echo "- _memory/${ag}-sidecar/decisions/${DATE}-${SLUG}.md"
  done <<< "$MEM_WT_LIST"
  echo ""
} > "$tmp"

mv "$tmp" "$out"

exit 0
