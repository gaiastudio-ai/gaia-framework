#!/usr/bin/env bash
# memory-writethrough.sh — gaia-meeting per-agent sidecar decision write-through (E76-S3)
#
# AC6 / AC7 / FR-MTG-24 / FR-MTG-25 / TC-MTG-MEM-1 / TC-MTG-MEM-2 / TC-MTG-MEM-3
#
# Reads a per-agent draft directory (`<agent>.md` files, one per accepted
# entry) and renders one decision file per agent at the canonical sidecar
# location:
#   <root>/_memory/<agent>-sidecar/decisions/<YYYY-MM-DD>-<slug>.md
#
# The output frontmatter contains: agent, date, source_meeting, type: decision,
# tags. The body contains the four mandatory H2 sections in fixed order:
#   1. ## What I decided / agreed to in this meeting
#   2. ## Constraints I committed to
#   3. ## Open items I'm tracking
#   4. ## Sources I relied on
#
# Each input draft is itself a small frontmatter+body file in this loose
# schema:
#   ---
#   agent: <name>
#   decided:    [ - "..." ]
#   constraints:[ - "..." ]
#   open_items: [ - "AI-..." ]
#   sources:    [ - "<path-or-url>" ]
#   tags:       [ - "<tag>" ]
#   ---
#
# Atomic writes: each output file is written to a sibling tempfile and `mv`d
# into place.
#
# Usage:
#   memory-writethrough.sh \
#     --root <project-root> \
#     --drafts <dir-with-agent-files> \
#     --source-meeting <slug> \
#     --date <YYYY-MM-DD> \
#     --slug <slug>
#
# Exit codes:
#   0 = success (or zero accepted drafts — nothing to write)
#   2 = invalid args
#   3 = I/O error

set -euo pipefail

ROOT=""
DRAFTS=""
SOURCE_MEETING=""
DATE=""
SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)            ROOT="$2"; shift 2 ;;
    --drafts)          DRAFTS="$2"; shift 2 ;;
    --source-meeting)  SOURCE_MEETING="$2"; shift 2 ;;
    --date)            DATE="$2"; shift 2 ;;
    --slug)            SLUG="$2"; shift 2 ;;
    *) echo "memory-writethrough.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ROOT" || -z "$DRAFTS" || -z "$SOURCE_MEETING" || -z "$DATE" || -z "$SLUG" ]]; then
  echo "memory-writethrough.sh: --root, --drafts, --source-meeting, --date, --slug required" >&2
  exit 2
fi

if [[ ! -d "$DRAFTS" ]]; then
  echo "memory-writethrough.sh: drafts dir not found: $DRAFTS" >&2
  exit 3
fi

# Helper: extract a YAML list block (lines like `  - "x"`) under a top-level
# key. Returns one item per line, each item already trimmed of quotes.
_extract_list() {
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_block = 0 }
    # Match top-level key:
    $0 ~ ("^" k ":[[:space:]]*$") { in_block = 1; next }
    # Leave the block on next top-level key or end-of-frontmatter.
    in_block && /^[A-Za-z_][A-Za-z0-9_]*:/ { in_block = 0 }
    in_block && /^---[[:space:]]*$/ { in_block = 0 }
    in_block && /^[[:space:]]+-[[:space:]]+/ {
      sub(/^[[:space:]]+-[[:space:]]+/, "")
      gsub(/^"/, "")
      gsub(/"$/, "")
      print
    }
  ' "$file"
}

shopt -s nullglob
drafts=("$DRAFTS"/*.md)
shopt -u nullglob

if [[ ${#drafts[@]} -eq 0 ]]; then
  exit 0  # nothing accepted — not an error
fi

for draft in "${drafts[@]}"; do
  agent="$(basename "$draft" .md)"

  out_dir="$ROOT/_memory/${agent}-sidecar/decisions"
  out="$out_dir/${DATE}-${SLUG}.md"
  mkdir -p "$out_dir"

  tmp="$(mktemp)"

  {
    echo "---"
    echo "agent: ${agent}"
    echo "date: ${DATE}"
    echo "source_meeting: ${SOURCE_MEETING}"
    echo "type: decision"
    echo "tags:"
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      echo "  - \"${tag}\""
    done < <(_extract_list "$draft" tags)
    echo "---"
    echo ""
    echo "## What I decided / agreed to in this meeting"
    echo ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "- ${line}"
    done < <(_extract_list "$draft" decided)
    echo ""
    echo "## Constraints I committed to"
    echo ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "- ${line}"
    done < <(_extract_list "$draft" constraints)
    echo ""
    echo "## Open items I'm tracking"
    echo ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "- ${line}"
    done < <(_extract_list "$draft" open_items)
    echo ""
    echo "## Sources I relied on"
    echo ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "- ${line}"
    done < <(_extract_list "$draft" sources)
  } > "$tmp"

  mv "$tmp" "$out"
done

exit 0
