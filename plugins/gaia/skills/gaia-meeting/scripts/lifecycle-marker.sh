#!/usr/bin/env bash
# lifecycle-marker.sh — gaia-meeting seven-phase lifecycle marker emitter
# (E76-S1, FR-MTG-1, AC3, TC-MTG-CHARTER-3)
#
# Emits a deterministic phase-marker line for the live transcript at each
# phase boundary. The saved meeting transcript at
# docs/creative-artifacts/meeting-{YYYY-MM-DD}-{slug}.md MUST contain markers
# in this order: INVITE, CHARTER, RESEARCH (skip placeholder in S1),
# DISCUSS, CLOSE, REVIEW, SAVE.
#
# Usage:
#   lifecycle-marker.sh --phase INVITE
#
# Exit codes:
#   0 = marker emitted
#   3 = unknown phase / malformed args

set -euo pipefail

KNOWN_PHASES=(INVITE CHARTER RESEARCH DISCUSS CLOSE REVIEW SAVE)

PHASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)   PHASE="${2-}"; shift 2 ;;
    --phase=*) PHASE="${1#--phase=}"; shift ;;
    *)
      echo "lifecycle-marker.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$PHASE" ]]; then
  echo "lifecycle-marker.sh: --phase is required (one of: ${KNOWN_PHASES[*]})" >&2
  exit 3
fi

known=0
for p in "${KNOWN_PHASES[@]}"; do
  if [[ "$p" == "$PHASE" ]]; then
    known=1
    break
  fi
done

if [[ "$known" -ne 1 ]]; then
  echo "lifecycle-marker.sh: unknown phase '$PHASE'. Known: ${KNOWN_PHASES[*]}" >&2
  exit 3
fi

# RESEARCH is a skip placeholder in S1 (full research-phase semantics ship in
# E76-S2 / ADR-084). The marker still appears so AC3's static check sees the
# full phase sequence.
if [[ "$PHASE" == "RESEARCH" ]]; then
  echo "## Phase: RESEARCH (skipped — research-phase semantics land in E76-S2 / ADR-084)"
else
  echo "## Phase: $PHASE"
fi

exit 0
