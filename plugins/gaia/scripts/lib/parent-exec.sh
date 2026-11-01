#!/usr/bin/env bash
# parent-exec.sh — sanitized env-i launcher for detached runners.
#
# Launches a command under env -i with a curated allowlist that explicitly
# excludes credential source variables.  Used by the smoke runner and
# reused by downstream executor stories.
#
# Usage (as script):
#   parent-exec.sh [--detach] -- <command> [args...]
#
# Usage (as library):
#   source parent-exec.sh
#   parent_exec_run [--detach] -- <command> [args...]
#
# The --detach flag launches the command through detach.sh (new process
# group).  Without --detach, the command runs in the foreground under env -i.
#
# Exit codes:
#   0 — command completed successfully (or launched when --detach)
#   1 — error (missing command, detach failure, etc.)
#
# Security: the allowlist NEVER includes credential source variables.
# Any variable matching the credential denylist is stripped even if it
# appears in the allowlist (defense in depth).
#
# Bash 3.2 compatible.

set -euo pipefail
LC_ALL=C; export LC_ALL

_PE_SCRIPT_NAME="parent-exec.sh"
_PE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_pe_log() { printf '%s: %s\n' "$_PE_SCRIPT_NAME" "$*" >&2; }

# Credential source variables that MUST NEVER be forwarded.
# This list is the denylist; any match is stripped regardless of the
# allowlist contents (defense in depth).
_PE_CREDENTIAL_DENYLIST=(
  GITHUB_TOKEN
  GH_TOKEN
  GITHUB_PAT
  GH_ENTERPRISE_TOKEN
  NPM_TOKEN
  NPM_AUTH_TOKEN
  YARN_AUTH_TOKEN
  AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN
  AZURE_CLIENT_SECRET
  GOOGLE_APPLICATION_CREDENTIALS
  DOCKER_PASSWORD
  DOCKER_AUTH_CONFIG
  VAULT_TOKEN
  ANTHROPIC_API_KEY
  OPENAI_API_KEY
  SSH_AUTH_SOCK
  GPG_PASSPHRASE
)

# Safe environment variables allowed through env -i.
_PE_ALLOWLIST=(
  PATH
  HOME
  USER
  LOGNAME
  SHELL
  TERM
  LANG
  LC_ALL
  TZ
  TMPDIR
  XDG_RUNTIME_DIR
)

# parent_exec_build_env — builds the env -i argument list.
# Outputs one VAR=value per line for variables in the allowlist that are
# set and not in the credential denylist.
parent_exec_build_env() {
  local var="" val=""
  for var in "${_PE_ALLOWLIST[@]}"; do
    # Check against credential denylist (defense in depth)
    local _is_denied=0
    local _dv=""
    for _dv in "${_PE_CREDENTIAL_DENYLIST[@]}"; do
      if [ "$var" = "$_dv" ]; then
        _is_denied=1
        break
      fi
    done
    [ "$_is_denied" -eq 1 ] && continue

    # Only forward if set in the current environment
    eval "val=\"\${${var}:-}\"" 2>/dev/null || val=""
    if [ -n "$val" ]; then
      printf '%s=%s\n' "$var" "$val"
    fi
  done
}

# parent_exec_run [--detach] -- <command> [args...]
parent_exec_run() {
  local use_detach=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --detach) use_detach=1; shift ;;
      --)       shift; break ;;
      *)        break ;;
    esac
  done

  if [ $# -eq 0 ]; then
    _pe_log "error: no command specified"
    return 1
  fi

  # Build env -i arguments
  local env_args=()
  local line=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    env_args+=("$line")
  done < <(parent_exec_build_env)

  if [ "$use_detach" -eq 1 ]; then
    local detach_lib="${_PE_SCRIPT_DIR}/detach.sh"
    if [ ! -f "$detach_lib" ]; then
      _pe_log "error: detach.sh not found at $detach_lib"
      return 1
    fi
    # Source detach.sh for the detach_run function
    # shellcheck source=detach.sh
    . "$detach_lib"
    detach_run env -i "${env_args[@]}" "$@"
  else
    env -i "${env_args[@]}" "$@"
  fi
}

# When invoked as a script (not sourced), parse args and run.
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${BASH_SOURCE[0]:-}" = "" ]; then
  parent_exec_run "$@"
fi
