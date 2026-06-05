#!/usr/bin/env bash
# resolve-user-name.sh — gaia-meeting user-interjection name resolver
#
# Resolution order (override wins):
#   1. meeting.user_name from project settings.json
#   2. git config user.name (fallback)
#
# The resolution is explicit: do NOT fall through to OS username.
# If neither source resolves, exit non-zero.
#
# Usage:
#   resolve-user-name.sh                               # uses ./settings.json or .claude/settings.json
#   resolve-user-name.sh --settings /path/to/file.json # explicit settings file
#
# Exit codes:
#   0 = name echoed on stdout
#   2 = neither source resolves a name

set -euo pipefail

SETTINGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings)   SETTINGS="${2-}"; shift 2 ;;
    --settings=*) SETTINGS="${1#--settings=}"; shift ;;
    *)
      echo "resolve-user-name.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

# Default settings.json discovery if not explicitly passed
if [[ -z "$SETTINGS" ]]; then
  if [[ -f ".claude/settings.json" ]]; then
    SETTINGS=".claude/settings.json"
  elif [[ -f "settings.json" ]]; then
    SETTINGS="settings.json"
  fi
fi

# Try meeting.user_name override first
if [[ -n "$SETTINGS" ]] && [[ -f "$SETTINGS" ]]; then
  if command -v jq >/dev/null 2>&1; then
    name="$(jq -r '.meeting.user_name // empty' "$SETTINGS" 2>/dev/null || true)"
  else
    # Minimal grep fallback for environments without jq — looks for
    # "user_name": "..." within the meeting block. Best-effort; jq is preferred.
    name="$(awk '
      /"meeting"[[:space:]]*:/ { in_block = 1 }
      in_block && /"user_name"[[:space:]]*:/ {
        match($0, /"user_name"[[:space:]]*:[[:space:]]*"([^"]*)"/, arr)
        if (arr[1] != "") { print arr[1]; exit }
      }
      in_block && /\}/ { in_block = 0 }
    ' "$SETTINGS" 2>/dev/null || true)"
  fi
  if [[ -n "$name" ]]; then
    echo "$name"
    exit 0
  fi
fi

# Fallback: git config user.name
if command -v git >/dev/null 2>&1; then
  git_name="$(git config user.name 2>/dev/null || true)"
  if [[ -n "$git_name" ]]; then
    echo "$git_name"
    exit 0
  fi
fi

echo "resolve-user-name.sh: could not resolve user name from settings.json (meeting.user_name) or git config user.name" >&2
exit 2
