#!/usr/bin/env bash
# emit-step-boundary.sh — emit a step_boundary lifecycle event
#
# Thin wrapper around lifecycle-event.sh that reduces the per-step boilerplate
# in gaia-dev-story SKILL.md to a single one-liner.
#
# Usage:
#   emit-step-boundary.sh <step_number> <step_name> <story_key>
#
# Example:
#   emit-step-boundary.sh 1 load-story {story_key}
#
# Emits:
#   lifecycle-event.sh --type step_boundary --workflow dev-story \
#     --step <step_number> --story <story_key> --data '{"step_name":"<step_name>"}'
#
# Exit codes:
#   0 — event emitted
#   1 — usage error or lifecycle-event.sh failure

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="emit-step-boundary.sh"

if [ $# -lt 3 ]; then
  printf '%s: usage: %s <step_number> <step_name> <story_key>\n' \
    "$SCRIPT_NAME" "$SCRIPT_NAME" >&2
  exit 1
fi

STEP_NUM="$1"
STEP_NAME="$2"
STORY_KEY="$3"

# Resolve lifecycle-event.sh relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIFECYCLE_EVENT="${SCRIPT_DIR}/../../../scripts/lifecycle-event.sh"

if [ ! -f "$LIFECYCLE_EVENT" ]; then
  printf '%s: lifecycle-event.sh not found at %s\n' "$SCRIPT_NAME" "$LIFECYCLE_EVENT" >&2
  exit 1
fi

exec bash "$LIFECYCLE_EVENT" \
  --type step_boundary \
  --workflow dev-story \
  --step "$STEP_NUM" \
  --story "$STORY_KEY" \
  --data "{\"step_name\":\"${STEP_NAME}\"}"
