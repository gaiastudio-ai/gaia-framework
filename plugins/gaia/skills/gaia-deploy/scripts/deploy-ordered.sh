#!/usr/bin/env bash
# deploy-ordered.sh — dependency-ordered per-stack deploy with health gate.
#
# Reads stacks from project-config.yaml, sorts by deploy_order (ascending),
# deploys each stack sequentially, and runs its health check (if configured)
# before proceeding to the next stack.
#
# Supports two modes:
#   strict      (default) — a health-check failure halts all downstream stacks.
#   best-effort — a health-check failure marks the component HOLD, leaves
#                 already-deployed components live, marks downstream dependents
#                 SKIPPED, and emits a PARTIAL-DEPLOY composite verdict with a
#                 per-component status table.
#
# In best-effort mode, a version-manifest snapshot is written before the first
# component deploys. If a crash/interrupt occurs, a restart reads the snapshot
# and resumes from the last incomplete component rather than restarting the
# entire sequence. On successful completion, the snapshot is archived.
#
# Stacks without deploy_order are deployed AFTER all ordered stacks, in
# alphabetical order by name — no undefined behavior.
#
# Usage:
#   deploy-ordered.sh --config <yaml> --env <env> --version <ver> \
#     --output-dir <dir> [--deploy-bin <path>] [--health-bin <path>] \
#     [--smoke-bin <path>] [--mode strict|best-effort] [--state-dir <dir>]
#
# Injectable binaries (test seams):
#   --deploy-bin  — executable invoked with --stack/--env/--version/--output-dir
#   --health-bin  — executable invoked with --command/--timeout/--stack
#   --smoke-bin   — executable invoked with --command/--timeout/--stack
#
# Exit codes:
#   0 — all stacks deployed + health checks passed
#   1 — health-check failure or timeout halted downstream stacks (strict mode)
#   3 — partial deploy completed with HOLD/SKIPPED components (best-effort mode)
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
  DEPLOY_MODE="strict"
  STATE_DIR=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --config)     CONFIG_PATH="$2"; shift 2 ;;
      --env)        ENV_NAME="$2"; shift 2 ;;
      --version)    VERSION="$2"; shift 2 ;;
      --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
      --deploy-bin) DEPLOY_BIN="$2"; shift 2 ;;
      --health-bin) HEALTH_BIN="$2"; shift 2 ;;
      --smoke-bin)  SMOKE_BIN="$2"; shift 2 ;;
      --mode)       DEPLOY_MODE="$2"; shift 2 ;;
      --state-dir)  STATE_DIR="$2"; shift 2 ;;
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
  if [ "$DEPLOY_MODE" != "strict" ] && [ "$DEPLOY_MODE" != "best-effort" ]; then
    _log_err "invalid --mode: $DEPLOY_MODE (must be strict or best-effort)"
    exit 2
  fi
  if [ "$DEPLOY_MODE" = "best-effort" ] && [ -z "$STATE_DIR" ]; then
    _log_err "--state-dir is required for best-effort mode (manifest/crash-recovery needs a writable state directory)"
    exit 2
  fi
  mkdir -p "$OUTPUT_DIR"
  if [ -n "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR"
  fi
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
      in_stacks = 0; in_item = 0; in_hc = 0; in_smoke = 0; in_envs = 0
      item_indent = -1
      name = ""; deploy_order = "999999"; hc_cmd = ""; hc_timeout = "30"
      smoke_cmd = ""; smoke_timeout = "60"; envs = ""
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
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", deploy_order, name, (hc_cmd == "" ? "_NONE_" : hc_cmd), hc_timeout, (smoke_cmd == "" ? "_NONE_" : smoke_cmd), smoke_timeout, (envs == "" ? "_ALL_" : envs)
          }
          in_item = 1; in_hc = 0; in_smoke = 0; in_envs = 0
          name = ""; deploy_order = "999999"; hc_cmd = ""; hc_timeout = "30"
          smoke_cmd = ""; smoke_timeout = "60"; envs = ""

          # Check for an inline key on the dash line: "- name: foo" or
          # "- environments: [...]" / "- environments:" (block follows).
          # A new item resets in_envs=0 above; an `environments:` key here must
          # re-arm it, otherwise a stack that lists environments FIRST on its
          # dash line would emit the _ALL_ sentinel and fail OPEN (the
          # restricted stack would deploy into every environment).
          line = $0
          sub(/^[[:space:]]+-[[:space:]]+/, "", line)
          if (match(line, /^name[[:space:]]*:/)) {
            name = extract_val(line)
          } else if (match(line, /^deploy_order[[:space:]]*:/)) {
            deploy_order = extract_val(line) + 0
          } else if (match(line, /^environments[[:space:]]*:/)) {
            in_envs = 1
            envval = line
            sub(/^[^:]*:[[:space:]]*/, "", envval)
            envval = trim(strip_comment(envval))
            if (envval ~ /^\[.*\]$/) {
              inner = substr(envval, 2, length(envval) - 2)
              n = split(inner, parts, ",")
              for (pi = 1; pi <= n; pi++) {
                e = trim(parts[pi])
                if (e ~ /^".*"$/) e = substr(e, 2, length(e) - 2)
                else if (e ~ /^'\''.*'\''$/) e = substr(e, 2, length(e) - 2)
                if (e != "") envs = (envs == "" ? e : envs "|" e)
              }
            }
          }
        } else if (in_envs && in_item) {
          # Deeper dash inside an `environments:` block — a scalar list entry.
          # Collect it (pipe-joined). Other sub-array dashes (paths:, etc.)
          # are not inside in_envs, so they remain ignored.
          envline = $0
          sub(/^[[:space:]]*-[[:space:]]+/, "", envline)
          envline = trim(strip_comment(envline))
          if (envline ~ /^".*"$/) envline = substr(envline, 2, length(envline) - 2)
          else if (envline ~ /^'\''.*'\''$/) envline = substr(envline, 2, length(envline) - 2)
          if (envline != "") envs = (envs == "" ? envline : envs "|" envline)
        }
        # Sub-array items (deeper dashes) are ignored unless captured above.
        next
      }

      if (!in_item) next

      # Item-level key indent = item_indent + 2 (e.g., 4 for 2-space items).
      item_key_indent = item_indent + 2

      # health_check / post_deploy_smoke / environments block starts.
      if (ind == item_key_indent && match($0, /health_check[[:space:]]*:/)) {
        in_hc = 1; in_smoke = 0; in_envs = 0; next
      }
      if (ind == item_key_indent && match($0, /post_deploy_smoke[[:space:]]*:/)) {
        in_smoke = 1; in_hc = 0; in_envs = 0; next
      }
      if (ind == item_key_indent && match($0, /environments[[:space:]]*:/)) {
        in_envs = 1; in_hc = 0; in_smoke = 0
        # Support the inline-flow form: `environments: [staging, prod]` (and
        # the empty `environments: []`). The block form (deeper "- value"
        # lines) is handled by the env-collector blocks. Extract any inline
        # bracketed value here so the flow form is not silently dropped
        # (which would fail OPEN — the stack would deploy into every env).
        envval = $0
        sub(/^[^:]*:[[:space:]]*/, "", envval)
        envval = trim(strip_comment(envval))
        if (envval ~ /^\[.*\]$/) {
          inner = substr(envval, 2, length(envval) - 2)   # drop [ ]
          n = split(inner, parts, ",")
          for (pi = 1; pi <= n; pi++) {
            e = trim(parts[pi])
            if (e ~ /^".*"$/) e = substr(e, 2, length(e) - 2)
            else if (e ~ /^'\''.*'\''$/) e = substr(e, 2, length(e) - 2)
            if (e != "") envs = (envs == "" ? e : envs "|" e)
          }
        }
        next
      }

      # Any item-level key exits sub-blocks.
      if (ind == item_key_indent) {
        in_hc = 0; in_smoke = 0; in_envs = 0
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
      # environments sub-list entries: deeper "- envname" lines. Collect each
      # into a pipe-joined string (the deploy resolver splits on "|").
      if (in_envs && ind > item_key_indent && match($0, /^[[:space:]]*-[[:space:]]/)) {
        envline = $0
        sub(/^[[:space:]]*-[[:space:]]+/, "", envline)
        envline = trim(strip_comment(envline))
        if (envline ~ /^".*"$/) envline = substr(envline, 2, length(envline) - 2)
        else if (envline ~ /^'\''.*'\''$/) envline = substr(envline, 2, length(envline) - 2)
        if (envline != "") envs = (envs == "" ? envline : envs "|" envline)
        next
      }
    }

    END {
      if (in_item && name != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", deploy_order, name, (hc_cmd == "" ? "_NONE_" : hc_cmd), hc_timeout, (smoke_cmd == "" ? "_NONE_" : smoke_cmd), smoke_timeout, (envs == "" ? "_ALL_" : envs)
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
# Version-manifest snapshot: write / read / archive
# ---------------------------------------------------------------------------

# write_manifest_snapshot — atomically writes pre-deploy manifest to state-dir.
# Args: state_dir env_name version stacks_data
write_manifest_snapshot() {
  local state_dir="$1"
  local env_name="$2"
  local version="$3"
  local stacks_data="$4"

  local manifest_path="$state_dir/deploy-manifest.json"
  local tmp_path="${manifest_path}.tmp.$$"

  # Build components array from stacks_data (tab-separated lines).
  local components_json="[]"
  while IFS=$'\t' read -r order name _hc_cmd _hc_timeout _smoke_cmd _smoke_timeout _envs; do
    [ -z "$name" ] && continue
    components_json="$(printf '%s' "$components_json" | jq \
      --arg name "$name" \
      --argjson order "$order" \
      --arg ver "$version" \
      '. + [{"name": $name, "deploy_order": $order, "target_version": $ver, "outcome": "PENDING", "health_result": null}]')"
  done <<< "$stacks_data"

  jq -n \
    --arg env "$env_name" \
    --arg ver "$version" \
    --arg status "in-progress" \
    --argjson components "$components_json" \
    '{env: $env, version: $ver, status: $status, components: $components}' \
    > "$tmp_path"

  mv "$tmp_path" "$manifest_path"
  _log_info "manifest snapshot written: $manifest_path"
}

# read_manifest_snapshot — reads an existing in-progress manifest. Returns 1 if none exists.
read_manifest_snapshot() {
  local state_dir="$1"
  local manifest_path="$state_dir/deploy-manifest.json"

  if [ ! -f "$manifest_path" ]; then
    return 1
  fi

  local status
  status="$(jq -r '.status' "$manifest_path")"
  if [ "$status" != "in-progress" ]; then
    return 1
  fi

  cat "$manifest_path"
  return 0
}

# _update_manifest_component — updates a single component in the manifest.
_update_manifest_component() {
  local state_dir="$1"
  local comp_name="$2"
  local outcome="$3"
  local health_result="$4"

  local manifest_path="$state_dir/deploy-manifest.json"
  local tmp_path="${manifest_path}.tmp.$$"

  jq \
    --arg name "$comp_name" \
    --arg outcome "$outcome" \
    --arg health "$health_result" \
    '.components = [.components[] | if .name == $name then .outcome = $outcome | .health_result = $health else . end]' \
    "$manifest_path" > "$tmp_path"

  mv "$tmp_path" "$manifest_path"
}

# _archive_manifest — archives the manifest and removes the in-progress file.
_archive_manifest() {
  local state_dir="$1"
  local output_dir="$2"
  local final_status="$3"

  local manifest_path="$state_dir/deploy-manifest.json"
  if [ ! -f "$manifest_path" ]; then
    return 0
  fi

  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local archive_path="$output_dir/deploy-manifest-${timestamp}.json"
  local tmp_path="${archive_path}.tmp.$$"

  jq --arg status "$final_status" '.status = $status' "$manifest_path" > "$tmp_path"
  mv "$tmp_path" "$archive_path"

  # Remove the in-progress manifest.
  rm -f "$manifest_path"
  _log_info "manifest archived: $archive_path"
}

# ---------------------------------------------------------------------------
# Per-component status table writer
# ---------------------------------------------------------------------------

# write_component_status — writes the per-component status table as JSON.
# Args: output_dir component_entries_json
write_component_status() {
  local output_dir="$1"
  local entries_json="$2"
  local status_path="$output_dir/component-status.json"
  printf '%s\n' "$entries_json" > "$status_path"
  _log_info "component status table written: $status_path"
}

# ---------------------------------------------------------------------------
# Advisory: warn when a deploy targeted ZERO stacks.
#
# With per-stack environment targeting it is now easy to mistype --env (e.g.
# `--env prde`) and have EVERY stack skip as "not targeted", yielding a silent
# 0/N no-op that still exits 0. This advisory surfaces that likely-mistake
# without changing the exit code (the deploy genuinely did nothing wrong — it
# just did nothing). Only fires when there ARE stacks to deploy but none were.
# ---------------------------------------------------------------------------

_warn_if_no_stacks_targeted() {
  local deployed="$1" total="$2" env_name="$3"
  if [ "$total" -gt 0 ] && [ "$deployed" -eq 0 ]; then
    _log_info "WARNING: 0 of $total stack(s) deployed to env=$env_name — every stack was skipped (env not targeted or upstream HOLD). If this was unexpected, check the --env value and each stack's declared environments[]."
  fi
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
  local mode="${8:-strict}"
  local state_dir="${9:-}"

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
  _log_info "deploying $total stack(s) to env=$env_name version=$version mode=$mode"

  # -----------------------------------------------------------------------
  # Best-effort mode: manifest snapshot + crash recovery + status table
  # -----------------------------------------------------------------------
  local has_hold=0
  local has_skip=0
  local component_status="[]"
  local resume_manifest=""

  if [ "$mode" = "best-effort" ] && [ -n "$state_dir" ]; then
    # Check for an existing in-progress manifest (crash recovery).
    resume_manifest="$(read_manifest_snapshot "$state_dir" 2>/dev/null || true)"

    if [ -z "$resume_manifest" ]; then
      # Fresh deploy — write the pre-deploy snapshot.
      write_manifest_snapshot "$state_dir" "$env_name" "$version" "$stacks_data"
    else
      _log_info "resuming from existing manifest snapshot"
    fi
  fi

  while IFS=$'\t' read -r order name hc_cmd hc_timeout smoke_cmd smoke_timeout stack_envs; do
    [ -z "$name" ] && continue
    # Sentinel replacement: _NONE_ = no command configured.
    [ "$hc_cmd" = "_NONE_" ] && hc_cmd=""
    [ "$smoke_cmd" = "_NONE_" ] && smoke_cmd=""

    # ----- Per-stack environment targeting: skip stacks not scoped to this env -----
    # `stack_envs` is a pipe-joined list of declared target environments, or the
    # `_ALL_` sentinel when the stack declared no `environments` (or an empty
    # list). `_ALL_` / empty = deploy into every environment (zero-regression
    # default). A non-empty list deploys ONLY into a matching environment.
    if [ -n "$stack_envs" ] && [ "$stack_envs" != "_ALL_" ]; then
      local _env_match=0
      local _IFS_save="$IFS"
      IFS='|'
      # shellcheck disable=SC2086
      set -- $stack_envs
      IFS="$_IFS_save"
      local _e
      for _e in "$@"; do
        if [ "$_e" = "$env_name" ]; then _env_match=1; break; fi
      done
      if [ "$_env_match" -eq 0 ]; then
        _log_info "skipping stack=$name — not targeted at env=$env_name (declared environments: ${stack_envs//|/, })"
        component_status="$(printf '%s' "$component_status" | jq \
          --arg comp "$name" --arg ver "$version" \
          '. + [{"component": $comp, "target_version": $ver, "outcome": "SKIPPED", "health_result": "env-not-targeted", "smoke_result": "n/a"}]')"
        if [ -n "$state_dir" ]; then
          _update_manifest_component "$state_dir" "$name" "SKIPPED" "env-not-targeted"
        fi
        continue
      fi
    fi

    # ----- Best-effort crash recovery: skip already-DEPLOYED components -----
    if [ "$mode" = "best-effort" ] && [ -n "$resume_manifest" ]; then
      local prev_outcome
      prev_outcome="$(printf '%s' "$resume_manifest" | jq -r --arg n "$name" '.components[] | select(.name == $n) | .outcome')"
      if [ "$prev_outcome" = "DEPLOYED" ]; then
        _log_info "crash-recovery: skipping already-deployed stack=$name"
        local prev_health
        prev_health="$(printf '%s' "$resume_manifest" | jq -r --arg n "$name" '.components[] | select(.name == $n) | .health_result // "n/a"')"
        local prev_smoke
        prev_smoke="$(printf '%s' "$resume_manifest" | jq -r --arg n "$name" '.components[] | select(.name == $n) | .smoke_result // "n/a"')"
        component_status="$(printf '%s' "$component_status" | jq \
          --arg comp "$name" --arg ver "$version" --arg health "$prev_health" --arg smoke "$prev_smoke" \
          '. + [{"component": $comp, "target_version": $ver, "outcome": "DEPLOYED", "health_result": $health, "smoke_result": $smoke}]')"
        deployed=$((deployed + 1))
        continue
      fi
    fi

    # ----- Best-effort: if a prior component was HOLD, downstream is SKIPPED -----
    if [ "$mode" = "best-effort" ] && [ "$has_hold" -eq 1 ]; then
      _log_info "skipping downstream stack=$name (upstream component on HOLD)"
      component_status="$(printf '%s' "$component_status" | jq \
        --arg comp "$name" --arg ver "$version" \
        '. + [{"component": $comp, "target_version": $ver, "outcome": "SKIPPED", "health_result": "n/a", "smoke_result": "n/a"}]')"
      has_skip=1
      if [ -n "$state_dir" ]; then
        _update_manifest_component "$state_dir" "$name" "SKIPPED" "n/a"
      fi
      continue
    fi

    # --- Deploy the stack ---
    _log_info "deploying stack=$name (deploy_order=$order)"
    local deploy_rc=0
    "$deploy_bin" --stack "$name" --env "$env_name" --version "$version" \
      --output-dir "$output_dir" || deploy_rc=$?

    if [ "$deploy_rc" -ne 0 ]; then
      _log_err "deploy FAILED for stack=$name (exit $deploy_rc)"
      if [ "$mode" = "best-effort" ]; then
        component_status="$(printf '%s' "$component_status" | jq \
          --arg comp "$name" --arg ver "$version" \
          '. + [{"component": $comp, "target_version": $ver, "outcome": "HOLD", "health_result": "deploy-failed", "smoke_result": "n/a"}]')"
        has_hold=1
        if [ -n "$state_dir" ]; then
          _update_manifest_component "$state_dir" "$name" "HOLD" "deploy-failed"
        fi
        continue
      fi
      printf 'HALTED: deploy failed for stack %s — downstream stacks not deployed\n' "$name"
      return 1
    fi
    deployed=$((deployed + 1))

    # --- Health check (if configured) ---
    local hc_result="n/a"
    if [ -n "$hc_cmd" ]; then
      local hc_rc=0
      _run_health_check "$name" "$hc_cmd" "$hc_timeout" "$health_bin" || hc_rc=$?

      if [ "$hc_rc" -eq 124 ]; then
        # Timeout path.
        local stderr_content=""
        [ -f "$output_dir/health-${name}.stderr" ] && stderr_content="$(cat "$output_dir/health-${name}.stderr")"
        _log_err "health-check TIMED OUT for stack=$name after ${hc_timeout}s"

        if [ "$mode" = "best-effort" ]; then
          hc_result="timeout"
          component_status="$(printf '%s' "$component_status" | jq \
            --arg comp "$name" --arg ver "$version" --arg health "$hc_result" \
            '. + [{"component": $comp, "target_version": $ver, "outcome": "HOLD", "health_result": $health, "smoke_result": "n/a"}]')"
          has_hold=1
          if [ -n "$state_dir" ]; then
            _update_manifest_component "$state_dir" "$name" "HOLD" "$hc_result"
          fi
          continue
        fi

        printf 'HALTED: health-check timed out for stack %s after %ss — downstream stacks not deployed\n' "$name" "$hc_timeout"
        [ -n "$stderr_content" ] && printf 'health-check output: %s\n' "$stderr_content"
        return 1

      elif [ "$hc_rc" -ne 0 ]; then
        local stderr_content=""
        [ -f "$output_dir/health-${name}.stderr" ] && stderr_content="$(cat "$output_dir/health-${name}.stderr")"
        _log_err "health-check FAILED for stack=$name (exit $hc_rc)"

        if [ "$mode" = "best-effort" ]; then
          hc_result="fail"
          component_status="$(printf '%s' "$component_status" | jq \
            --arg comp "$name" --arg ver "$version" --arg health "$hc_result" \
            '. + [{"component": $comp, "target_version": $ver, "outcome": "HOLD", "health_result": $health, "smoke_result": "n/a"}]')"
          has_hold=1
          if [ -n "$state_dir" ]; then
            _update_manifest_component "$state_dir" "$name" "HOLD" "$hc_result"
          fi
          continue
        fi

        printf 'HALTED: health-check failed for stack %s (exit %d) — downstream stacks not deployed\n' "$name" "$hc_rc"
        [ -n "$stderr_content" ] && printf 'health-check output: %s\n' "$stderr_content"
        return 1
      fi
      hc_result="pass"
      _log_info "health-check PASSED for stack=$name"
    fi

    # --- Post-deploy smoke (if configured) ---
    local smoke_result="n/a"
    if [ -n "$smoke_cmd" ]; then
      local smoke_rc=0
      _run_smoke "$name" "$smoke_cmd" "$smoke_timeout" "$smoke_bin" || smoke_rc=$?

      if [ "$smoke_rc" -ne 0 ]; then
        _log_err "post-deploy-smoke FAILED for stack=$name (exit $smoke_rc)"
        if [ "$mode" = "best-effort" ]; then
          component_status="$(printf '%s' "$component_status" | jq \
            --arg comp "$name" --arg ver "$version" --arg health "$hc_result" \
            '. + [{"component": $comp, "target_version": $ver, "outcome": "HOLD", "health_result": $health, "smoke_result": "fail"}]')"
          has_hold=1
          if [ -n "$state_dir" ]; then
            _update_manifest_component "$state_dir" "$name" "HOLD" "smoke-failed"
          fi
          continue
        fi
        printf 'HALTED: post-deploy smoke failed for stack %s — downstream stacks not deployed\n' "$name"
        return 1
      fi
      smoke_result="pass"
      _log_info "post-deploy-smoke PASSED for stack=$name"
    fi

    # Component deployed successfully.
    if [ "$mode" = "best-effort" ]; then
      component_status="$(printf '%s' "$component_status" | jq \
        --arg comp "$name" --arg ver "$version" --arg health "$hc_result" --arg smoke "$smoke_result" \
        '. + [{"component": $comp, "target_version": $ver, "outcome": "DEPLOYED", "health_result": $health, "smoke_result": $smoke}]')"
      if [ -n "$state_dir" ]; then
        _update_manifest_component "$state_dir" "$name" "DEPLOYED" "$hc_result"
      fi
    fi

  done <<< "$stacks_data"

  # -----------------------------------------------------------------------
  # Best-effort post-deploy: status table + verdict + manifest archive
  # -----------------------------------------------------------------------
  if [ "$mode" = "best-effort" ]; then
    write_component_status "$output_dir" "$component_status"

    if [ "$has_hold" -eq 1 ] || [ "$has_skip" -eq 1 ]; then
      # Partial deploy — archive manifest as partial.
      if [ -n "$state_dir" ]; then
        _archive_manifest "$state_dir" "$output_dir" "partial"
      fi
      _log_info "partial deploy: $deployed/$total deployed, HOLD/SKIPPED present"
      printf 'PARTIAL-DEPLOY\n'
      return 3
    fi

    # All deployed successfully — archive manifest as completed.
    if [ -n "$state_dir" ]; then
      _archive_manifest "$state_dir" "$output_dir" "completed"
    fi
    _warn_if_no_stacks_targeted "$deployed" "$total" "$env_name"
    _log_info "ordered deploy complete: $deployed/$total stacks deployed to env=$env_name"
    printf 'PASSED\n'
    return 0
  fi

  _warn_if_no_stacks_targeted "$deployed" "$total" "$env_name"
  _log_info "ordered deploy complete: $deployed/$total stacks deployed to env=$env_name"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_deploy_args "$@"
  run_ordered_deploy "$CONFIG_PATH" "$ENV_NAME" "$VERSION" "$OUTPUT_DIR" \
    "$DEPLOY_BIN" "$HEALTH_BIN" "$SMOKE_BIN" "$DEPLOY_MODE" "$STATE_DIR"
}

# Main-guard: sourcing exposes functions without side-effects.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
