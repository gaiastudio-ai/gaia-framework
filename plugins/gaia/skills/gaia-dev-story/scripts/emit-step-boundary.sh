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
# context-window snapshot). The object is validated by a two-layer privacy guard:
#   1. All scalar (leaf) values must be numbers — no strings, no booleans, no nulls.
#   2. All keys must be a SUBSET of the canonical allowlist:
#      input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens
# Any violation (non-numeric value OR non-allowlisted key) causes the snapshot to
# be silently dropped (graceful-skip). This guarantees that neither arbitrary text
# in values NOR arbitrary text in key names can ever reach the telemetry payload.
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
    --tokens)
      # Guard: require a value argument after the flag. If --tokens is the
      # last arg with nothing following, treat it as a missing value and
      # graceful-skip (omit the token field) instead of crashing on shift 2.
      if [ "$#" -ge 2 ]; then
        TOKENS_JSON="$2"
        shift 2
      else
        shift  # consume the bare --tokens flag, leave TOKENS_JSON empty
      fi
      ;;
    *) shift ;;  # silently skip unknown flags (forward-compat)
  esac
done

# Auto-capture the persisted context-window snapshot when no explicit --tokens
# payload was supplied. statusline.sh is the only component the substrate hands
# `.context_window.current_usage` to, and it persists the latest cumulative
# snapshot to ${MEMORY_PATH}/.context-window-snapshot.json. Reading it here is
# what connects the producer (statusline) to the consumer (this event), so real
# dev-story runs land per-step token data instead of timing only. The snapshot
# is re-validated by the same privacy gate below, so a stale/garbage file can
# never smuggle anything in — worst case it is dropped (graceful-skip). An
# explicit --tokens always wins (this branch only runs when it was absent).
# Best-effort: an absent or unreadable file leaves TOKENS_JSON empty and the
# event lands with timing data only.
if [ -z "$TOKENS_JSON" ]; then
  SNAPSHOT_FILE="${MEMORY_PATH:-.gaia/memory}/.context-window-snapshot.json"
  if [ -r "$SNAPSHOT_FILE" ]; then
    TOKENS_JSON="$(cat "$SNAPSHOT_FILE" 2>/dev/null || printf '')"
  fi
fi

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
# payload passes the two-layer privacy gate:
#   Layer 1 — shape + values: (a) valid JSON, (b) is an object (not array or
#     scalar), (c) ALL leaf (scalar) values are numbers — no strings, booleans,
#     or nulls.
#   Layer 2 — key allowlist: every key in the object must be one of the four
#     canonical context-window fields. This closes the key-name smuggling path
#     where arbitrary text could reach the payload via object keys (jq's
#     `.. | scalars` does not surface keys).
# When any check fails the snapshot is silently dropped and the event lands
# with timing data only (graceful-skip).
if [ -n "$TOKENS_JSON" ]; then
  # Validate: parseable JSON + object type + all scalars numeric + keys allowlisted.
  VALID=$(printf '%s' "$TOKENS_JSON" | jq -e '
    type == "object"
    and ([.. | scalars] | length > 0)
    and ([.. | scalars] | map(type == "number") | all)
    and ((keys - ["input_tokens","output_tokens","cache_creation_input_tokens","cache_read_input_tokens"]) | length == 0)
  ' 2>/dev/null || printf 'false')
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
