#!/usr/bin/env bash
# scratchpad-extractor.sh — gaia-meeting extracted-file writer (E76-S4)
#
# AC5 / AC8 / AC10 / AC11 / AC12 / AC14 / FR-MTG-13 / FR-MTG-14 / FR-MTG-15.
#
# Writes a single scratchpad extraction:
#   1. Resolves the deterministic path via scratchpad-resolve-path.sh.
#   2. Detects content-type via scratchpad-detect-type.sh (when --content-type
#      is omitted) — both helpers are the single source of truth.
#   3. Routes the relative path through write-boundary.sh (FR-MTG-31 / AC14).
#   4. Lazily creates {YYYY-MM} and {slug} directories (no .gitkeep — AC12).
#   5. Atomically writes via mktemp + mv (replace-at-same-path AC10).
#   6. Composes the six-field frontmatter contract (AC8) plus the content body.
#
# Usage:
#   scratchpad-extractor.sh \
#     --root <project-root> \
#     --date <YYYY-MM-DD> \
#     --slug <meeting-slug> \
#     --sp-n SP-<N> \
#     --content <content-string> \
#     --intent <intent-string> \
#     --pinning-agent <agent-name> \
#     --action-items <comma-separated-AI-ids-or-empty> \
#     [--content-type <auto|json|ts|py|sh|md|go|swift|kt|rs|java>]
#
# Exit codes:
#   0 = success (absolute path emitted to stdout)
#   2 = invalid args / write-boundary rejection
#   3 = I/O error

set -euo pipefail
LC_ALL=C
export LC_ALL

ROOT=""
DATE=""
SLUG=""
SP_N=""
CONTENT=""
INTENT=""
AGENT=""
AI_LIST=""
CTYPE="auto"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/scratchpad-resolve-path.sh"
DETECT="$SCRIPT_DIR/scratchpad-detect-type.sh"
BOUNDARY="$SCRIPT_DIR/write-boundary.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  scratchpad-extractor.sh --root <project-root> --date <YYYY-MM-DD> --slug <s>
    --sp-n SP-<N> --content <s> --intent <s> --pinning-agent <s>
    --action-items "<AI-...>,<AI-...>" [--content-type <ext>]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)           ROOT="$2"; shift 2 ;;
    --date)           DATE="$2"; shift 2 ;;
    --slug)           SLUG="$2"; shift 2 ;;
    --sp-n)           SP_N="$2"; shift 2 ;;
    --content)        CONTENT="$2"; shift 2 ;;
    --intent)         INTENT="$2"; shift 2 ;;
    --pinning-agent)  AGENT="$2"; shift 2 ;;
    --action-items)   AI_LIST="$2"; shift 2 ;;
    --content-type)   CTYPE="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$ROOT" || -z "$DATE" || -z "$SLUG" || -z "$SP_N" || -z "$AGENT" ]]; then
  usage
  exit 2
fi

# Slug guard (defense-in-depth — also enforced by resolver)
case "$SLUG" in
  *..*|*/*|.*) echo "scratchpad-extractor.sh: invalid --slug: $SLUG" >&2; exit 2 ;;
esac

# Resolve content-type if requested
if [[ "$CTYPE" == "auto" || -z "$CTYPE" ]]; then
  CTYPE="$(printf '%s' "$CONTENT" | "$DETECT")"
fi

# Resolve relative extraction path
REL_PATH="$("$RESOLVE" \
  --date "$DATE" \
  --slug "$SLUG" \
  --sp-n "$SP_N" \
  --content "$CONTENT" \
  --intent "$INTENT" \
  --content-type "$CTYPE")"

# Gate through write-boundary.sh (FR-MTG-31, AC14)
if ! "$BOUNDARY" "$REL_PATH" >/dev/null; then
  echo "scratchpad-extractor.sh: write-boundary REJECTED $REL_PATH" >&2
  exit 2
fi

ABS_PATH="$ROOT/$REL_PATH"
ABS_DIR="$(dirname "$ABS_PATH")"

# Lazy directory creation (AC12 — no .gitkeep)
mkdir -p "$ABS_DIR"

# ISO-8601 UTC timestamp (Technical Notes)
EXTRACTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Compose the frontmatter inline-list for source_action_items
ai_inline="["
if [[ -n "$AI_LIST" ]]; then
  IFS=',' read -ra ai_arr <<< "$AI_LIST"
  first=1
  for ai in "${ai_arr[@]}"; do
    # Trim leading/trailing whitespace
    ai="${ai#"${ai%%[![:space:]]*}"}"
    ai="${ai%"${ai##*[![:space:]]}"}"
    [[ -z "$ai" ]] && continue
    if [[ $first -eq 1 ]]; then
      ai_inline+="$ai"
      first=0
    else
      ai_inline+=", $ai"
    fi
  done
fi
ai_inline+="]"

SOURCE_MEETING="meeting-${DATE}-${SLUG}.md"

# Atomic write via mktemp + mv
TMP="$(mktemp "${ABS_DIR}/.scratchpad.XXXXXX")"
{
  echo "---"
  echo "source_meeting: ${SOURCE_MEETING}"
  echo "source_scratchpad_id: ${SP_N}"
  echo "source_action_items: ${ai_inline}"
  echo "extracted_by: gaia-meeting"
  echo "extracted_at: ${EXTRACTED_AT}"
  echo "content_type: ${CTYPE}"
  echo "---"
  echo ""
  printf '%s' "$CONTENT"
  # Ensure trailing newline
  if [[ -n "$CONTENT" ]] && [[ "${CONTENT: -1}" != $'\n' ]]; then
    printf '\n'
  fi
} > "$TMP"

mv "$TMP" "$ABS_PATH"

printf '%s\n' "$ABS_PATH"
