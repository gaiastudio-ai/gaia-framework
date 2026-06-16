#!/usr/bin/env bash
# emit-step-boundary.sh — emit a step_boundary lifecycle event
#
# Thin wrapper around lifecycle-event.sh that reduces the per-step boilerplate
# in gaia-dev-story SKILL.md to a single one-liner.
#
# Usage:
#   emit-step-boundary.sh <step_number> <step_name> <story_key> [--tokens <json>]
#
# Example:
#   emit-step-boundary.sh 1 load-story {story_key}
#   emit-step-boundary.sh 1 load-story {story_key} --tokens '{"input_tokens":5000,...}'
#
# The --tokens flag accepts a JSON object of cumulative token counts (best-effort
# context-window snapshot). The object MUST contain ONLY numeric leaf values —
# any string value causes the snapshot to be silently dropped (privacy guard).
# When --tokens is absent or invalid, the event lands without a tokens_snapshot
# field (graceful-skip — timing data is never blocked by token unavailability).
#
# Emits:
#   lifecycle-event.sh --type step_boundary --workflow dev-story \
#     --step <step_number> --story <story_key> \
#     --data '{"step_name":"<step_name>"[,"tokens_snapshot":{...}]}'
#
# Exit codes:
#   0 — event emitted
#   1 — usage error or lifecycle-event.sh failure

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="emit-step-boundary.sh"

if [ $# -lt 3 ]; then
  printf '%s: usage: %s <step_number> <step_name> <story_key> [--tokens <json>]\n' \
    "$SCRIPT_NAME" "$SCRIPT_NAME" >&2
  exit 1
fi

STEP_NUM="$1"
STEP_NAME="$2"
STORY_KEY="$3"
shift 3

# Parse optional named flags after the three required positional args.
TOKENS_JSON=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tokens) TOKENS_JSON="${2:-}"; shift 2 ;;
    *) shift ;;  # silently skip unknown flags (forward-compat)
  esac
done

# Resolve lifecycle-event.sh relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIFECYCLE_EVENT="${SCRIPT_DIR}/../../../scripts/lifecycle-event.sh"

if [ ! -f "$LIFECYCLE_EVENT" ]; then
  printf '%s: lifecycle-event.sh not found at %s\n' "$SCRIPT_NAME" "$LIFECYCLE_EVENT" >&2
  exit 1
fi

# Build the --data JSON via jq for safe construction — no shell interpolation
# into JSON, which would break on names containing quotes or backslashes.
DATA_JSON=$(jq -nc --arg name "$STEP_NAME" '{"step_name":$name}')

# Merge tokens_snapshot into --data when the --tokens flag was supplied AND the
# payload passes the privacy gate: (a) valid JSON, (b) is an object (not array
# or scalar), (c) ALL leaf (scalar) values are numbers — no strings, no booleans,
# no nulls. This is the hard guarantee that prompt/response text can NEVER land
# in the payload. When any check fails the snapshot is silently dropped and the
# event lands with timing data only (graceful-skip).
if [ -n "$TOKENS_JSON" ]; then
  # Validate: parseable JSON + object type + all scalars are numbers.
  VALID=$(printf '%s' "$TOKENS_JSON" | jq -e \
    'type == "object" and ([.. | scalars] | length > 0) and ([.. | scalars] | map(type == "number") | all)' \
    2>/dev/null || printf 'false')
  if [ "$VALID" = "true" ]; then
    # Merge tokens_snapshot into the data object. The jq -s slurp merges the
    # base data with the snapshot wrapped as {tokens_snapshot: <snapshot>}.
    DATA_JSON=$(printf '%s\n%s' "$DATA_JSON" "$TOKENS_JSON" \
      | jq -sc '.[0] * {tokens_snapshot: .[1]}')
  fi
  # else: silently skip — graceful-skip path (AC3)
fi

exec bash "$LIFECYCLE_EVENT" \
  --type step_boundary \
  --workflow dev-story \
  --step "$STEP_NUM" \
  --story "$STORY_KEY" \
  --data "$DATA_JSON"
