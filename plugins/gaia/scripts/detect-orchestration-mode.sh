#!/usr/bin/env bash
# detect-orchestration-mode.sh — E84-S3 / ADR-093 §"Dual-Mode Dispatch".
#
# Resolves which orchestration mode the framework should use at the start
# of a GAIA skill execution. Emits exactly one of:
#   subagent     (Mode A, default; subagent re-dispatch with checkpoint payloads)
#   team         (Mode B, opt-in; persistent teammates via Agent Teams)
# to stdout.
#
# Mode B requires BOTH:
#   - CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 (env or settings.json)
#   - orchestration.mode: team in config/project-config.yaml
#
# If either is absent, falls back silently to Mode A per FR-445 AC.
#
# Exit codes:
#   0 — mode resolved (always); read stdout
#   2 — usage error
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -eu
LC_ALL=C
export LC_ALL

SCRIPT_NAME="detect-orchestration-mode.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  detect-orchestration-mode.sh [--config <path>] [--env-flag <var-name>]

Defaults:
  --config:     config/project-config.yaml (resolved relative to CWD)
  --env-flag:   CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

Emits one of: subagent | team
USAGE
}

config_path="config/project-config.yaml"
env_flag_name="CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"

while [ $# -gt 0 ]; do
  case "$1" in
    --config) config_path="${2:-}"; shift 2 ;;
    --config=*) config_path="${1#--config=}"; shift ;;
    --env-flag) env_flag_name="${2:-}"; shift 2 ;;
    --env-flag=*) env_flag_name="${1#--env-flag=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2; usage; exit 2 ;;
  esac
done

# ---- Check 1: env flag ----
# Dereference the variable named in $env_flag_name. eval is fenced; the
# variable name comes from a flag whitelist, never user input on stdin.
env_val=""
eval "env_val=\${${env_flag_name}:-}"

if [ "$env_val" != "1" ]; then
  printf 'subagent\n'
  exit 0
fi

# ---- Check 2: orchestration.mode in project-config.yaml ----
mode_val=""
if [ -r "$config_path" ]; then
  # YAML-light parser — just looking for `orchestration:` block then `mode:`
  # value. Indentation-tolerant, comment-tolerant. Bash 3.2 compatible.
  mode_val="$(awk '
    /^orchestration:[[:space:]]*$/ { in_orch=1; next }
    in_orch && /^[a-zA-Z_-]+:/ && !/^[[:space:]]/ { in_orch=0 }
    in_orch && /^[[:space:]]+mode:/ {
      sub(/^[[:space:]]+mode:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/^"/, ""); sub(/"$/, "")
      sub(/^'\''/, ""); sub(/'\''$/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$config_path" 2>/dev/null || printf '')"
fi

if [ "$mode_val" = "team" ]; then
  printf 'team\n'
else
  printf 'subagent\n'
fi
