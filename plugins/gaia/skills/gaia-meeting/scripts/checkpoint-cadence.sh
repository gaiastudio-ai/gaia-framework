#!/usr/bin/env bash
# checkpoint-cadence.sh — load `meeting.checkpoint_every_n_turns` from
# settings.json.
#
# Default 4. Honored verbatim in [1, 10]. Out-of-range values clamp:
#   <= 0  -> 1
#   >  10 -> 10
# A single-line WARNING is emitted to stderr on any clamp event.
#
# Usage:
#   checkpoint-cadence.sh --settings <path/to/settings.json>
#
# Output:
#   stdout: the resolved integer (1..10)
#   stderr: optional single-line WARNING when clamping

set -euo pipefail

SETTINGS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings)   SETTINGS="${2-}"; shift 2 ;;
    --settings=*) SETTINGS="${1#--settings=}"; shift ;;
    *)
      echo "checkpoint-cadence.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

DEFAULT=4
RAW=""

# Read settings.json if it exists. We avoid hard-depending on jq — fall back
# to a tolerant grep + sed pull. The schema is a top-level "meeting" object
# with a "checkpoint_every_n_turns" integer field.
if [[ -n "$SETTINGS" && -f "$SETTINGS" ]]; then
  if command -v jq >/dev/null 2>&1; then
    RAW="$(jq -r '.meeting.checkpoint_every_n_turns // empty' "$SETTINGS" 2>/dev/null || true)"
  else
    # Tolerant fallback — match `"checkpoint_every_n_turns": <int>` anywhere
    # in the file. Good enough for the common case where the file is a
    # straightforward nested object; jq is the recommended path.
    RAW="$(grep -Eo '"checkpoint_every_n_turns"[[:space:]]*:[[:space:]]*-?[0-9]+' "$SETTINGS" \
            | head -1 \
            | sed -E 's/.*:[[:space:]]*(-?[0-9]+).*/\1/' || true)"
  fi
fi

if [[ -z "$RAW" ]]; then
  printf '%s\n' "$DEFAULT"
  exit 0
fi

# Validate it parses as an integer.
if ! [[ "$RAW" =~ ^-?[0-9]+$ ]]; then
  printf '[gaia-meeting] WARNING: meeting.checkpoint_every_n_turns is not an integer (got "%s") — using default %d\n' "$RAW" "$DEFAULT" >&2
  printf '%s\n' "$DEFAULT"
  exit 0
fi

VAL="$RAW"
if (( VAL < 1 )); then
  printf '[gaia-meeting] WARNING: meeting.checkpoint_every_n_turns=%d is out of range [1, 10] — clamping to 1\n' "$VAL" >&2
  VAL=1
elif (( VAL > 10 )); then
  printf '[gaia-meeting] WARNING: meeting.checkpoint_every_n_turns=%d is out of range [1, 10] — clamping to 10\n' "$VAL" >&2
  VAL=10
fi

printf '%s\n' "$VAL"
exit 0
