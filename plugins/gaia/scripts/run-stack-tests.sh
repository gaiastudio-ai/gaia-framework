#!/usr/bin/env bash
# run-stack-tests.sh — resolve and execute the test command for a named stack
#
# Reads a stack name from the CLI, resolves the appropriate test command
# using the project config, and exec's into it. Resolution order:
#   1. Per-stack test_cmd field in project-config.yaml (if present)
#   2. Language-based default (bash→bats, typescript→npm test,
#      python→pytest, java→mvn test, go→go test ./...)
#
# Usage:
#   run-stack-tests.sh [--config <project-config.yaml>] <stack-name>
#
# Exit codes:
#   0 — test command succeeded
#   1 — resolution error (unknown stack, unsupported language, missing args)
#   N — whatever the test command exits with

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Internal helpers (underscore prefix — exempt from NFR-052 gate)
# ---------------------------------------------------------------------------
_log_info() {
  printf '[run-stack-tests] INFO: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# usage — print help to stdout and exit 0
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  run-stack-tests.sh [--config <project-config.yaml>] <stack-name>

Options:
  --config PATH   Path to project-config.yaml.
  --help          Print this message and exit 0.

Arguments:
  stack-name      The name of the stack whose tests to run.

Resolution order:
  1. Per-stack test_cmd field (if present in config)
  2. Language-based default

Exit codes:
  0  Test command succeeded.
  1  Resolution error (unknown stack, unsupported language).
  N  Test command exit code.
USAGE
}

# ---------------------------------------------------------------------------
# parse_args — populate _CONFIG and _STACK_NAME
# ---------------------------------------------------------------------------
parse_args() {
  _CONFIG=""
  _STACK_NAME=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)  _CONFIG="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      -*)
        printf 'run-stack-tests.sh: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
      *)
        if [[ -z "$_STACK_NAME" ]]; then
          _STACK_NAME="$1"
          shift
        else
          printf 'run-stack-tests.sh: unexpected argument: %s\n' "$1" >&2
          exit 1
        fi
        ;;
    esac
  done

  if [[ -z "$_STACK_NAME" ]]; then
    printf 'run-stack-tests.sh: stack name is required\n' >&2
    usage >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# resolve_language_for_stack STACK_NAME CONFIG_PATH
#   Emit the language field for the named stack. Exit 1 if not found.
# ---------------------------------------------------------------------------
resolve_language_for_stack() {
  local stack_name="$1"
  local config="$2"

  if [[ ! -f "$config" ]]; then
    printf 'run-stack-tests.sh: config file not found: %s\n' "$config" >&2
    return 1
  fi

  # Pure awk parser — no yq/jq dependency.
  # Walks the stacks: block, finds the matching name:, and emits language:.
  local language
  language="$(awk '
    /^stacks:/ { in_stacks=1; next }
    in_stacks && /^[^ ]/ && !/^stacks:/ { exit }
    in_stacks && /^  - name:/ {
      gsub(/^  - name:[ \t]*/, "")
      gsub(/["'"'"']/, "")
      gsub(/[ \t]+$/, "")
      current_name = $0
      next
    }
    in_stacks && /^    language:/ && current_name == "'"$stack_name"'" {
      gsub(/^    language:[ \t]*/, "")
      gsub(/["'"'"']/, "")
      gsub(/[ \t]+$/, "")
      print
      exit
    }
  ' "$config")"

  if [[ -z "$language" ]]; then
    return 1
  fi
  printf '%s' "$language"
}

# ---------------------------------------------------------------------------
# _resolve_test_cmd_from_config STACK_NAME CONFIG_PATH
#   Check if the config has a per-stack test_cmd field. Emit it if found.
# ---------------------------------------------------------------------------
_resolve_test_cmd_from_config() {
  local stack_name="$1"
  local config="$2"

  if [[ ! -f "$config" ]]; then
    return 1
  fi

  local test_cmd
  test_cmd="$(awk '
    /^stacks:/ { in_stacks=1; next }
    in_stacks && /^[^ ]/ && !/^stacks:/ { exit }
    in_stacks && /^  - name:/ {
      gsub(/^  - name:[ \t]*/, "")
      gsub(/["'"'"']/, "")
      gsub(/[ \t]+$/, "")
      current_name = $0
      next
    }
    in_stacks && /^    test_cmd:/ && current_name == "'"$stack_name"'" {
      gsub(/^    test_cmd:[ \t]*/, "")
      gsub(/^["'"'"']/, ""); gsub(/["'"'"']$/, "")
      gsub(/[ \t]+$/, "")
      print
      exit
    }
  ' "$config")"

  if [[ -z "$test_cmd" ]]; then
    return 1
  fi
  printf '%s' "$test_cmd"
}

# ---------------------------------------------------------------------------
# _default_test_command_for_language LANGUAGE
#   Emit the default test command for a known language. Exit 1 if unknown.
# ---------------------------------------------------------------------------
_default_test_command_for_language() {
  local language="$1"

  case "$language" in
    bash|shell)
      printf 'bats plugins/gaia/tests/'
      ;;
    typescript|javascript)
      printf 'npm test'
      ;;
    python)
      printf 'pytest'
      ;;
    java|kotlin-jvm)
      printf 'mvn test'
      ;;
    go|golang)
      printf 'go test ./...'
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# resolve_test_command STACK_NAME CONFIG_PATH
#   Emit the test command for the named stack on stdout.
#   Resolution: test_cmd field > language default.
# ---------------------------------------------------------------------------
resolve_test_command() {
  local stack_name="$1"
  local config="$2"

  # 1. Try per-stack test_cmd field first.
  local cmd
  if cmd="$(_resolve_test_cmd_from_config "$stack_name" "$config")"; then
    printf '%s' "$cmd"
    return 0
  fi

  # 2. Resolve language, then fall back to language default.
  local language
  if ! language="$(resolve_language_for_stack "$stack_name" "$config")"; then
    printf 'run-stack-tests.sh: stack not found in config: %s\n' "$stack_name" >&2
    return 1
  fi

  if ! cmd="$(_default_test_command_for_language "$language")"; then
    printf 'run-stack-tests.sh: no default test command for language: %s (stack: %s)\n' "$language" "$stack_name" >&2
    return 1
  fi

  printf '%s' "$cmd"
}

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  if [[ -z "$_CONFIG" ]]; then
    printf 'run-stack-tests.sh: --config is required\n' >&2
    exit 1
  fi

  _log_info "resolving test command for stack: $_STACK_NAME"

  local test_cmd
  if ! test_cmd="$(resolve_test_command "$_STACK_NAME" "$_CONFIG")"; then
    exit 1
  fi

  _log_info "executing: $test_cmd"

  # Execute the resolved command via eval to support multi-word commands
  # like "npm test" or "bats plugins/gaia/tests/".
  eval "$test_cmd"
}

# Main-guard: only invoke main when executed directly (not when sourced).
# Required for NFR-052 — sourcing must expose public functions without side-effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
