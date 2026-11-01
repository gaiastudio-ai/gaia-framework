#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# run-configured-commands.sh — deterministic runner for project-configured
# command arrays (preflight_commands, post_ci_smoke_commands).
#
# Usage:
#   run-configured-commands.sh --key <config_key> [--config <path>] [--workdir <dir>]
#
# Reads the named array from project-config.yaml via yq, executes each
# entry sequentially in --workdir (default ${PROJECT_PATH:-.}), and halts
# on the first non-zero exit with a message naming the failing command and
# its exit code.
#
# Exit codes:
#   0 — all commands passed (or array absent/empty)
#   1 — a configured command failed
#   2 — usage error
#
# TRUST BOUNDARY: the commands run unsandboxed with the user's own
# privileges. They come from the project config, which the user controls.

_usage() {
  printf 'usage: run-configured-commands.sh --key <config_key> [--config <path>] [--workdir <dir>]\n' >&2
  exit 2
}

config_key=""
config_path=""
workdir="${PROJECT_PATH:-.}"

while [ $# -gt 0 ]; do
  case "$1" in
    --key)    config_key="${2:-}"; shift 2 ;;
    --config) config_path="${2:-}"; shift 2 ;;
    --workdir) workdir="${2:-}"; shift 2 ;;
    *) _usage ;;
  esac
done

[ -z "$config_key" ] && _usage

# Resolve config path when not supplied.
if [ -z "$config_path" ]; then
  if [ -n "${PROJECT_CONFIG:-}" ] && [ -f "${PROJECT_CONFIG}" ]; then
    config_path="$PROJECT_CONFIG"
  elif [ -n "${CLAUDE_PROJECT_ROOT:-}" ] && [ -f "${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml" ]; then
    config_path="${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml"
  elif [ -f ".gaia/config/project-config.yaml" ]; then
    config_path=".gaia/config/project-config.yaml"
  fi
fi

# Key absent from config or config file missing — silent no-op.
if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
  exit 0
fi
if ! grep -qE "^${config_key}:" "$config_path" 2>/dev/null; then
  exit 0
fi

# yq is required when the key is present.
if ! command -v yq >/dev/null 2>&1; then
  printf 'run-configured-commands.sh: error: yq is required for %s but not found on PATH\n' "$config_key" >&2
  exit 1
fi

# Read the array as JSON and extract entries.
commands_json="$(yq -o=json ".${config_key}" "$config_path" 2>/dev/null)" || commands_json=""

# null or empty means the key was present but empty (e.g. `preflight_commands: []`).
if [ -z "$commands_json" ] || [ "$commands_json" = "null" ] || [ "$commands_json" = "[]" ]; then
  exit 0
fi

# jq is required to safely decode the JSON array.
if ! command -v jq >/dev/null 2>&1; then
  printf 'run-configured-commands.sh: error: jq is required to decode %s but not found on PATH\n' "$config_key" >&2
  exit 1
fi

count="$(printf '%s' "$commands_json" | jq -r 'length')"
if [ "$count" -eq 0 ]; then
  exit 0
fi

# Execute each command sequentially in the working directory.
i=0
while [ "$i" -lt "$count" ]; do
  cmd="$(printf '%s' "$commands_json" | jq -r ".[$i]")"
  i=$((i + 1))
  if [ -z "$cmd" ]; then
    continue
  fi
  printf 'run-configured-commands.sh: [%s %d/%d] %s\n' "$config_key" "$i" "$count" "$cmd" >&2
  rc=0
  ( cd "$workdir" && eval "$cmd" ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'run-configured-commands.sh: HALT: %s command failed: %s (exit %d)\n' "$config_key" "$cmd" "$rc" >&2
    exit 1
  fi
done

printf 'run-configured-commands.sh: %s: all %d commands passed\n' "$config_key" "$count" >&2
exit 0
