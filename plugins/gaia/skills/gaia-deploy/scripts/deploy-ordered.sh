#!/usr/bin/env bash
# deploy-ordered.sh — dependency-ordered per-stack deploy with health gate.
#
# Reads stacks from project-config.yaml, sorts by deploy_order (ascending),
# deploys each stack sequentially, and runs its health check (if configured)
# before proceeding to the next stack. A health-check failure or timeout
# halts all downstream stacks.
#
# Stacks without deploy_order are deployed AFTER all ordered stacks, in
# alphabetical order by name — no undefined behavior.
#
# Usage:
#   deploy-ordered.sh --config <yaml> --env <env> --version <ver> \
#     --output-dir <dir> [--deploy-bin <path>] [--health-bin <path>] \
#     [--smoke-bin <path>]
#
# Injectable binaries (test seams):
#   --deploy-bin  — executable invoked with --stack/--env/--version/--output-dir
#   --health-bin  — executable invoked with --command/--timeout/--stack
#   --smoke-bin   — executable invoked with --command/--timeout/--stack
#
# Exit codes:
#   0 — all stacks deployed + health checks passed
#   1 — health-check failure or timeout halted downstream stacks
#   2 — usage / config error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/deploy-ordered.sh"
_log_info() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_log_err()  { printf '%s: ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_deploy_args() {
  CONFIG_PATH=""
  ENV_NAME=""
  VERSION=""
  OUTPUT_DIR=""
  DEPLOY_BIN=""
  HEALTH_BIN=""
  SMOKE_BIN=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --config)     CONFIG_PATH="$2"; shift 2 ;;
      --env)        ENV_NAME="$2"; shift 2 ;;
      --version)    VERSION="$2"; shift 2 ;;
      --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
      --deploy-bin) DEPLOY_BIN="$2"; shift 2 ;;
      --health-bin) HEALTH_BIN="$2"; shift 2 ;;
      --smoke-bin)  SMOKE_BIN="$2"; shift 2 ;;
      -h|--help)
        printf '%s — dependency-ordered per-stack deploy with health gate.\n' "$SCRIPT_NAME"
        printf 'Usage: %s --config <yaml> --env <env> --version <ver> --output-dir <dir>\n' "$SCRIPT_NAME"
        exit 0
        ;;
      *)
        _log_err "unknown argument: $1"
        exit 2
        ;;
    esac
  done

  if [ -z "$CONFIG_PATH" ] || [ -z "$ENV_NAME" ] || [ -z "$VERSION" ] || [ -z "$OUTPUT_DIR" ]; then
    _log_err "required: --config, --env, --version, --output-dir"
    exit 2
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    _log_err "config file not found: $CONFIG_PATH"
    exit 2
  fi
  mkdir -p "$OUTPUT_DIR"
}

# ---------------------------------------------------------------------------
# Config parser: reads stacks with deploy_order, health_check, post_deploy_smoke
# ---------------------------------------------------------------------------
# Emits one line per stack:
#   <deploy_order_or_MAX>\t<name>\t<hc_command>\t<hc_timeout>\t<smoke_command>\t<smoke_timeout>
# Sorted by deploy_order ascending, then alphabetical name for ties / absent order.

read_stacks_deploy_config() {
  local config="$1"
  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function strip_comment(s) { sub(/[[:space:]]*#.*$/, "", s); return s }
    function extract_val(line) {
      sub(/^[^:]*:[[:space:]]*/, "", line)
      line = trim(strip_comment(line))
      # Strip wrapping quotes.
      if (line ~ /^".*"$/) line = substr(line, 2, length(line) - 2)
      else if (line ~ /^'\''.*'\''$/) line = substr(line, 2, length(line) - 2)
      return line
    }
    function indent_of(line,   n) {
      n = 0
      while (substr(line, n + 1, 1) == " ") n++
      return n
    }

    BEGIN {
      in_stacks = 0; in_item = 0; in_hc = 0; in_smoke = 0
      item_indent = -1
      name = ""; deploy_order = "999999"; hc_cmd = ""; hc_timeout = "30"
      smoke_cmd = ""; smoke_timeout = "60"
    }

    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^stacks[[:space:]]*:/ { in_stacks = 1; next }
    in_stacks && /^[a-zA-Z_]/ { in_stacks = 0 }

    in_stacks {
      ind = indent_of($0)

      # Detect a new stacks[] list item: a line with "- " whose dash indent
      # is at item_indent (or the first dash line sets item_indent).
      # Sub-array dashes (e.g. paths: entries) are deeper — ignore them.
      if (match($0, /^[[:space:]]+-[[:space:]]/)) {
        dash_ind = ind
        if (item_indent < 0) {
          # First list item — record the indent level.
          item_indent = dash_ind
        }
        if (dash_ind == item_indent) {
          # Flush previous item.
          if (in_item && name != "") {
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", deploy_order, name, (hc_cmd == "" ? "_NONE_" : hc_cmd), hc_timeout, (smoke_cmd == "" ? "_NONE_" : smoke_cmd), smoke_timeout
          }
          in_item = 1; in_hc = 0; in_smoke = 0
          name = ""; deploy_order = "999999"; hc_cmd = ""; hc_timeout = "30"
          smoke_cmd = ""; smoke_timeout = "60"

          # Check for inline name on the dash line: "- name: foo"
          line = $0
          sub(/^[[:space:]]+-[[:space:]]+/, "", line)
          if (match(line, /^name[[:space:]]*:/)) {
            name = extract_val(line)
          }
        }
        # Sub-array items (deeper dashes) are ignored.
        next
      }

      if (!in_item) next

      # Item-level key indent = item_indent + 2 (e.g., 4 for 2-space items).
      item_key_indent = item_indent + 2

      # health_check / post_deploy_smoke block starts.
      if (ind == item_key_indent && match($0, /health_check[[:space:]]*:/)) {
        in_hc = 1; in_smoke = 0; next
      }
      if (ind == item_key_indent && match($0, /post_deploy_smoke[[:space:]]*:/)) {
        in_smoke = 1; in_hc = 0; next
      }

      # Any item-level key exits sub-blocks.
      if (ind == item_key_indent) {
        in_hc = 0; in_smoke = 0
        if (match($0, /name[[:space:]]*:/)) { name = extract_val($0); next }
        if (match($0, /deploy_order[[:space:]]*:/)) { deploy_order = extract_val($0) + 0; next }
        # Other item-level keys (language, paths, etc.) — just skip.
        next
      }

      # Sub-block keys (deeper than item_key_indent).
      if (in_hc && ind > item_key_indent) {
        if (match($0, /command[[:space:]]*:/)) { hc_cmd = extract_val($0); next }
        if (match($0, /timeout[[:space:]]*:/)) { hc_timeout = extract_val($0) + 0; next }
      }
      if (in_smoke && ind > item_key_indent) {
        if (match($0, /command[[:space:]]*:/)) { smoke_cmd = extract_val($0); next }
        if (match($0, /timeout[[:space:]]*:/)) { smoke_timeout = extract_val($0) + 0; next }
      }
    }

    END {
      if (in_item && name != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", deploy_order, name, (hc_cmd == "" ? "_NONE_" : hc_cmd), hc_timeout, (smoke_cmd == "" ? "_NONE_" : smoke_cmd), smoke_timeout
      }
    }
  ' "$config" | sort -t$'\t' -k1,1n -k2,2
}

# ---------------------------------------------------------------------------
# Run health check with timeout enforcement
# ---------------------------------------------------------------------------

_run_health_check() {
  local stack_name="$1"
  local hc_cmd="$2"
  local hc_timeout="$3"
  local health_bin="$4"

  _log_info "health-check: stack=$stack_name command='$hc_cmd' timeout=${hc_timeout}s"

  local rc=0

  if command -v timeout >/dev/null 2>&1; then
    # GNU/BSD coreutils timeout available.
    timeout "$hc_timeout" "$health_bin" \
      --command "$hc_cmd" --timeout "$hc_timeout" --stack "$stack_name" 2>"$OUTPUT_DIR/health-${stack_name}.stderr" || rc=$?
  else
    # Fallback: background + wait with kill.
    "$health_bin" \
      --command "$hc_cmd" --timeout "$hc_timeout" --stack "$stack_name" 2>"$OUTPUT_DIR/health-${stack_name}.stderr" &
    local pid=$!
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$elapsed" -ge "$hc_timeout" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rc=124  # Same exit code as GNU timeout.
        break
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    if [ "$rc" -eq 0 ]; then
      wait "$pid" || rc=$?
    fi
  fi

  return "$rc"
}

# ---------------------------------------------------------------------------
# Run post-deploy smoke with timeout enforcement
# ---------------------------------------------------------------------------

_run_smoke() {
  local stack_name="$1"
  local smoke_cmd="$2"
  local smoke_timeout="$3"
  local smoke_bin="$4"

  _log_info "post-deploy-smoke: stack=$stack_name command='$smoke_cmd' timeout=${smoke_timeout}s"

  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "$smoke_timeout" "$smoke_bin" \
      --command "$smoke_cmd" --timeout "$smoke_timeout" --stack "$stack_name" 2>"$OUTPUT_DIR/smoke-${stack_name}.stderr" || rc=$?
  else
    "$smoke_bin" \
      --command "$smoke_cmd" --timeout "$smoke_timeout" --stack "$stack_name" 2>"$OUTPUT_DIR/smoke-${stack_name}.stderr" &
    local pid=$!
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$elapsed" -ge "$smoke_timeout" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rc=124
        break
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    if [ "$rc" -eq 0 ]; then
      wait "$pid" || rc=$?
    fi
  fi

  return "$rc"
}

# ---------------------------------------------------------------------------
# Main deploy orchestrator
# ---------------------------------------------------------------------------

run_ordered_deploy() {
  local config="$1"
  local env_name="$2"
  local version="$3"
  local output_dir="$4"
  local deploy_bin="$5"
  local health_bin="$6"
  local smoke_bin="$7"

  # Read and sort stacks.
  local stacks_data
  stacks_data="$(read_stacks_deploy_config "$config")"

  if [ -z "$stacks_data" ]; then
    _log_info "no stacks found in config — nothing to deploy"
    return 0
  fi

  local total=0
  local deployed=0
  total="$(printf '%s\n' "$stacks_data" | wc -l | tr -d ' ')"
  _log_info "deploying $total stack(s) to env=$env_name version=$version"

  while IFS=$'\t' read -r order name hc_cmd hc_timeout smoke_cmd smoke_timeout; do
    [ -z "$name" ] && continue
    # Sentinel replacement: _NONE_ = no command configured.
    [ "$hc_cmd" = "_NONE_" ] && hc_cmd=""
    [ "$smoke_cmd" = "_NONE_" ] && smoke_cmd=""

    # --- Deploy the stack ---
    _log_info "deploying stack=$name (deploy_order=$order)"
    local deploy_rc=0
    "$deploy_bin" --stack "$name" --env "$env_name" --version "$version" \
      --output-dir "$output_dir" || deploy_rc=$?

    if [ "$deploy_rc" -ne 0 ]; then
      _log_err "deploy FAILED for stack=$name (exit $deploy_rc)"
      printf 'HALTED: deploy failed for stack %s — downstream stacks not deployed\n' "$name"
      return 1
    fi
    deployed=$((deployed + 1))

    # --- Health check (if configured) ---
    if [ -n "$hc_cmd" ]; then
      local hc_rc=0
      _run_health_check "$name" "$hc_cmd" "$hc_timeout" "$health_bin" || hc_rc=$?

      if [ "$hc_rc" -eq 124 ]; then
        # Timeout path (exit 124 = GNU timeout signal).
        local stderr_content=""
        [ -f "$output_dir/health-${name}.stderr" ] && stderr_content="$(cat "$output_dir/health-${name}.stderr")"
        _log_err "health-check TIMED OUT for stack=$name after ${hc_timeout}s"
        printf 'HALTED: health-check timed out for stack %s after %ss — downstream stacks not deployed\n' "$name" "$hc_timeout"
        [ -n "$stderr_content" ] && printf 'health-check output: %s\n' "$stderr_content"
        return 1
      elif [ "$hc_rc" -ne 0 ]; then
        local stderr_content=""
        [ -f "$output_dir/health-${name}.stderr" ] && stderr_content="$(cat "$output_dir/health-${name}.stderr")"
        _log_err "health-check FAILED for stack=$name (exit $hc_rc)"
        printf 'HALTED: health-check failed for stack %s (exit %d) — downstream stacks not deployed\n' "$name" "$hc_rc"
        [ -n "$stderr_content" ] && printf 'health-check output: %s\n' "$stderr_content"
        return 1
      fi
      _log_info "health-check PASSED for stack=$name"
    fi

    # --- Post-deploy smoke (if configured) ---
    if [ -n "$smoke_cmd" ]; then
      local smoke_rc=0
      _run_smoke "$name" "$smoke_cmd" "$smoke_timeout" "$smoke_bin" || smoke_rc=$?

      if [ "$smoke_rc" -ne 0 ]; then
        _log_err "post-deploy-smoke FAILED for stack=$name (exit $smoke_rc)"
        printf 'HALTED: post-deploy smoke failed for stack %s — downstream stacks not deployed\n' "$name"
        return 1
      fi
      _log_info "post-deploy-smoke PASSED for stack=$name"
    fi

  done <<< "$stacks_data"

  _log_info "ordered deploy complete: $deployed/$total stacks deployed to env=$env_name"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_deploy_args "$@"
  run_ordered_deploy "$CONFIG_PATH" "$ENV_NAME" "$VERSION" "$OUTPUT_DIR" \
    "$DEPLOY_BIN" "$HEALTH_BIN" "$SMOKE_BIN"
}

# Main-guard: sourcing exposes functions without side-effects.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
