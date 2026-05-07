#!/usr/bin/env bash
# halt-event.sh — gaia-meeting structured halt-event emitter (E76-S6, AC9)
#
# Emits a deterministic single-line halt event to stdout for the live stream.
# Per FR-MTG-28 / NFR-MTG-1 / AC9, every hard guardrail (charter, research,
# cite-or-flag, write-boundary) terminates the meeting with this format:
#
#   HALT condition=<NAME> agent=<ID|—> fr=<FR-MTG-ID> detail=<text>
#
# The halt event is the terminal live-stream event. The lifecycle MUST exit
# cleanly after emitting it — no subsequent turn header, no cost-check, no
# farewell.
#
# Usage:
#   halt-event.sh --condition CHARTER-MISSING --fr FR-MTG-28 --detail "no charter"
#   halt-event.sh --condition CITE-OR-FLAG --agent theo --fr FR-MTG-28 \
#                 --detail "unflagged-inference at line 12"
#
# Exit codes:
#   0 = halt event emitted
#   3 = malformed args (missing required field)

set -euo pipefail

CONDITION=""
AGENT=""
FR=""
DETAIL=""
DETAIL_PROVIDED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --condition)   CONDITION="${2-}"; shift 2 ;;
    --condition=*) CONDITION="${1#--condition=}"; shift ;;
    --agent)       AGENT="${2-}"; shift 2 ;;
    --agent=*)     AGENT="${1#--agent=}"; shift ;;
    --fr)          FR="${2-}"; shift 2 ;;
    --fr=*)        FR="${1#--fr=}"; shift ;;
    --detail)      DETAIL="${2-}"; DETAIL_PROVIDED=1; shift 2 ;;
    --detail=*)    DETAIL="${1#--detail=}"; DETAIL_PROVIDED=1; shift ;;
    *)
      echo "halt-event.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$CONDITION" ]]; then
  echo "halt-event.sh: --condition is required" >&2
  exit 3
fi
if [[ -z "$FR" ]]; then
  echo "halt-event.sh: --fr is required" >&2
  exit 3
fi
if [[ "$DETAIL_PROVIDED" -eq 0 ]]; then
  echo "halt-event.sh: --detail is required" >&2
  exit 3
fi

# Default agent to em-dash for non-agent halts (charter, research, write-boundary).
if [[ -z "$AGENT" ]]; then
  AGENT="—"
fi

printf 'HALT condition=%s agent=%s fr=%s detail=%s\n' \
  "$CONDITION" "$AGENT" "$FR" "$DETAIL"

exit 0
