#!/usr/bin/env bash
# charter-gate.sh — gaia-meeting charter requirement guardrail (E76-S1, FR-MTG-2)
#
# Parses --charter "<inline>" and records the charter into MEETING_STATE_FILE.
# Exits non-zero with an actionable BLOCKED error when --charter is absent or
# empty. The skill orchestrator MUST invoke this script BEFORE any artifact
# write — when the gate fires, no creative-artifacts / action-items /
# sidecar-decisions write is permitted (FR-MTG-31, AC1).
#
# Usage:
#   charter-gate.sh --charter "Decide whether to adopt X for Y."
#
# Env:
#   MEETING_STATE_FILE — path to the in-memory state env file (default:
#                        $TMPDIR/gaia-meeting-state.env)
#
# Exit codes:
#   0 = charter accepted, written to MEETING_STATE_FILE
#   2 = BLOCKED — charter missing or empty
#   3 = malformed args

set -euo pipefail

CHARTER=""
CHARTER_PROVIDED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --charter)
      CHARTER_PROVIDED=1
      CHARTER="${2-}"
      shift 2
      ;;
    --charter=*)
      CHARTER_PROVIDED=1
      CHARTER="${1#--charter=}"
      shift
      ;;
    *)
      echo "charter-gate.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ "$CHARTER_PROVIDED" -eq 0 ]] || [[ -z "$CHARTER" ]]; then
  cat <<'EOF' >&2
charter-gate.sh: BLOCKED — meeting charter is required before INVITE.

Re-invoke /gaia-meeting with --charter "<one-to-three-sentence charter>".

Example:
  /gaia-meeting --charter "Decide whether to adopt X for Y."

No writes have been made to docs/creative-artifacts/, _memory/action-items/,
or _memory/{agent}-sidecar/decisions/ (FR-MTG-2, FR-MTG-31, AC1).
EOF
  # Echo BLOCKED on stdout for bats matchers and test consumers
  echo "charter-gate.sh: BLOCKED — meeting charter is required (use --charter \"...\")."
  exit 2
fi

STATE_FILE="${MEETING_STATE_FILE:-${TMPDIR:-/tmp}/gaia-meeting-state.env}"
mkdir -p "$(dirname "$STATE_FILE")"

# Escape the charter for safe env-file storage: quote and escape backslashes /
# double quotes. This is a deterministic capture — full meeting frontmatter
# persistence ships in E76-S3 (FR-MTG-27).
escaped="${CHARTER//\\/\\\\}"
escaped="${escaped//\"/\\\"}"
{
  echo "CHARTER=\"${escaped}\""
} > "$STATE_FILE"

echo "charter-gate.sh: charter accepted (${#CHARTER} chars)"
exit 0
