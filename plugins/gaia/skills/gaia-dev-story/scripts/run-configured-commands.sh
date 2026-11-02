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
#   0 — all commands passed (or array truly absent / empty array)
#   1 — a configured command failed, or a read error prevented the gate
#       from determining its answer (fail closed)
#   2 — usage error
#
# TRUST BOUNDARY: the commands run unsandboxed with the user's own
# privileges. They come from the project config, which the user controls.
# Changes to the committed config should be reviewed like any code change.

SCRIPT_NAME="$(basename "$0")"

_usage() {
  printf '%s: usage: --key <config_key> [--config <path>] [--workdir <dir>]\n' "$SCRIPT_NAME" >&2
  exit 2
}

_halt() {
  printf '%s: HALT: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

# discover_config — locate project-config.yaml using the same ladder as
# promotion-chain-guard.sh: $PROJECT_CONFIG > $CLAUDE_PROJECT_ROOT/.gaia/config >
# walk up from CWD (bounded to 8 levels).
discover_config() {
  if [ -n "${PROJECT_CONFIG:-}" ]; then
    printf '%s\n' "$PROJECT_CONFIG"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_ROOT:-}" ]; then
    if [ -f "${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml" ]; then
      printf '%s\n' "${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml"
      return 0
    fi
    if [ -f "${CLAUDE_PROJECT_ROOT}/config/project-config.yaml" ]; then
      printf '%s\n' "${CLAUDE_PROJECT_ROOT}/config/project-config.yaml"
      return 0
    fi
  fi
  local dir depth=0
  dir="$(pwd -P 2>/dev/null || pwd)"
  while [ -n "$dir" ] && [ "$depth" -lt 8 ]; do
    if [ -f "${dir}/.gaia/config/project-config.yaml" ]; then
      printf '%s\n' "${dir}/.gaia/config/project-config.yaml"
      return 0
    fi
    if [ -f "${dir}/config/project-config.yaml" ]; then
      printf '%s\n' "${dir}/config/project-config.yaml"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
    depth=$((depth + 1))
  done
  return 0
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
  config_path="$(discover_config)"
fi

# Config file not found anywhere — silent no-op (no project config means
# no commands configured).
if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
  exit 0
fi

# Config file must be readable. An unreadable file is a read error, not
# "key absent" — fail closed.
if [ ! -r "$config_path" ]; then
  _halt "config file not readable: ${config_path} (permission denied)"
fi

# Check whether the key exists. The grep must succeed cleanly — a grep
# failure on a readable file (e.g. binary, encoding) is a read error.
key_grep_rc=0
grep -qE "^${config_key}:" "$config_path" 2>/dev/null || key_grep_rc=$?
if [ "$key_grep_rc" -eq 1 ]; then
  # grep found no match — key truly absent, silent no-op.
  exit 0
elif [ "$key_grep_rc" -ne 0 ]; then
  # grep error (2+) — read error, fail closed.
  _halt "could not read config file: ${config_path} (grep exit ${key_grep_rc})"
fi

# yq is required when the key is present.
if ! command -v yq >/dev/null 2>&1; then
  _halt "yq is required for ${config_key} but not found on PATH"
fi

# Read the array as JSON. A yq failure on a readable file with the key
# present is a parse error — fail closed, never silently skip.
commands_json=""
yq_rc=0
commands_json="$(yq -o=json ".${config_key}" "$config_path" 2>&1)" || yq_rc=$?
if [ "$yq_rc" -ne 0 ]; then
  _halt "${config_key}: failed to parse config (yq exit ${yq_rc}): ${commands_json}"
fi

# null or empty array — the key was present but has no entries. Silent no-op.
if [ -z "$commands_json" ] || [ "$commands_json" = "null" ] || [ "$commands_json" = "[]" ]; then
  exit 0
fi

# jq is required to safely decode the JSON array.
if ! command -v jq >/dev/null 2>&1; then
  _halt "jq is required to decode ${config_key} but not found on PATH"
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
  printf '%s: [%s %d/%d] %s\n' "$SCRIPT_NAME" "$config_key" "$i" "$count" "$cmd" >&2
  rc=0
  ( cd "$workdir" && eval "$cmd" ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: HALT: %s command failed: %s (exit %d)\n' "$SCRIPT_NAME" "$config_key" "$cmd" "$rc" >&2
    exit 1
  fi
done

printf '%s: %s: all %d commands passed\n' "$SCRIPT_NAME" "$config_key" "$count" >&2
exit 0
