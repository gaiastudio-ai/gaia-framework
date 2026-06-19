#!/usr/bin/env bash
# promotion-trigger.sh — post-merge promotion orchestrator.
#
# Fires after a merge to the promotion branch. Orchestrates:
#   1. Release — resolve version strategy + bump version files.
#   2. Deploy  — dispatch per-environment deploys for affected components.
#
# The trigger reuses the affected-set data contract (three-tier fallback)
# and iterates the ci_cd.promotion_chain environments from project config.
#
# Injectable binaries (env vars default to the real scripts — for testing,
# override with shims that emit the same stdout/exit-code contract):
#   GAIA_RELEASE_BIN     — path to resolve-release-version.sh
#   GAIA_VERSION_BUMP_BIN — path to version-bump.js (invoked via node)
#   GAIA_DEPLOY_BIN      — path to deploy dispatch binary
#   GAIA_AFFECTED_SET_BIN — path to resolve-affected-set.sh
#
# Output:
#   Structured log lines on stdout.
#   Machine-readable JSON summary as the LAST stdout line.
#   Diagnostic/progress messages on stderr.
#
# Exit codes:
#   0 — release + all deploys succeeded
#   1 — release failed or one or more deploys failed
#   2 — usage / config error
#
# Usage:
#   promotion-trigger.sh --config <path> --project-root <path>

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Internal helpers (underscore prefix — exempt from public-fn coverage gate)
# ---------------------------------------------------------------------------

_log_info() { printf '[promotion-trigger] INFO: %s\n' "$*" >&2; }
_log_err()  { printf '[promotion-trigger] ERROR: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
  CONFIG_PATH=""
  PROJECT_ROOT=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --config)       CONFIG_PATH="$2"; shift 2 ;;
      --project-root) PROJECT_ROOT="$2"; shift 2 ;;
      --help|-h)
        printf 'Usage: promotion-trigger.sh --config <path> --project-root <path>\n'
        exit 0
        ;;
      *)
        _log_err "unknown argument: $1"
        exit 2
        ;;
    esac
  done

  if [ -z "$CONFIG_PATH" ]; then
    _log_err "--config <path> is required"
    exit 2
  fi
  if [ -z "$PROJECT_ROOT" ]; then
    _log_err "--project-root <path> is required"
    exit 2
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    _log_err "config file not found: $CONFIG_PATH"
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Config parsers (pure awk — no yq/jq dependency)
# ---------------------------------------------------------------------------

# _read_promotion_chain_ids CONFIG — extract ci_cd.promotion_chain[].id values.
# Emits one id per line.
_read_promotion_chain_ids() {
  local config="$1"
  awk '
    /^[[:space:]]*#/ { next }
    /^ci_cd[[:space:]]*:/ { in_cicd = 1; next }
    in_cicd && /^[^[:space:]]/ { in_cicd = 0 }
    in_cicd && /^[[:space:]]+promotion_chain[[:space:]]*:/ { in_chain = 1; next }
    in_chain && /^[^[:space:]-]/ { in_chain = 0 }
    in_chain && /^[[:space:]]+-[[:space:]]+/ {
      # A new list item — check for inline id.
      line = $0
      if (match(line, /id:[[:space:]]*/)) {
        val = substr(line, RSTART + RLENGTH)
        gsub(/^[[:space:]]+/, "", val)
        gsub(/[[:space:]]+$/, "", val)
        gsub(/"/, "", val)
        gsub(/'\''/, "", val)
        if (val != "") print val
        next
      }
    }
    in_chain && /^[[:space:]]+id[[:space:]]*:/ {
      val = $0
      sub(/^[[:space:]]+id[[:space:]]*:[[:space:]]*/, "", val)
      gsub(/[[:space:]]+$/, "", val)
      gsub(/"/, "", val)
      gsub(/'\''/, "", val)
      if (val != "") print val
    }
  ' "$config"
}

# _read_stack_names CONFIG — extract stacks[].name values.
# Emits one name per line.
_read_stack_names() {
  local config="$1"
  awk '
    /^stacks[[:space:]]*:/ { in_stacks = 1; next }
    in_stacks && /^[a-zA-Z_]/ { in_stacks = 0; next }
    in_stacks && /^[[:space:]]+-[[:space:]]+name:/ {
      val = $0
      sub(/.*name:[[:space:]]*/, "", val)
      gsub(/^[[:space:]]+/, "", val)
      gsub(/[[:space:]]+$/, "", val)
      gsub(/"/, "", val)
      gsub(/'\''/, "", val)
      if (val != "") print val
    }
  ' "$config"
}

# ---------------------------------------------------------------------------
# Resolve injectable binaries (defaults to real scripts)
# ---------------------------------------------------------------------------

_resolve_binaries() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  RELEASE_BIN="${GAIA_RELEASE_BIN:-$SCRIPT_DIR/../skills/gaia-release/scripts/resolve-release-version.sh}"
  VERSION_BUMP_BIN="${GAIA_VERSION_BUMP_BIN:-}"
  DEPLOY_BIN="${GAIA_DEPLOY_BIN:-$SCRIPT_DIR/../skills/gaia-deploy/scripts/deploy-dispatch.sh}"
  AFFECTED_SET_BIN="${GAIA_AFFECTED_SET_BIN:-$SCRIPT_DIR/resolve-affected-set.sh}"

  # version-bump.js: default to the real script invoked via node.
  if [ -z "$VERSION_BUMP_BIN" ]; then
    local vb_js="$SCRIPT_DIR/../skills/gaia-release/scripts/version-bump.js"
    if [ -f "$vb_js" ]; then
      VERSION_BUMP_BIN="$vb_js"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Phase 1: Release
#
# Invoke the release version resolver. Parse its key=value output.
# On bump=none or non-zero exit, emit failure summary and exit.
# On success, invoke version-bump to apply the version to files.
# ---------------------------------------------------------------------------

run_release() {
  _log_info "phase 1: release"

  local release_output rc=0
  release_output="$("$RELEASE_BIN" --config "$CONFIG_PATH" --project-root "$PROJECT_ROOT" 2>&1)" || rc=$?

  if [ "$rc" -ne 0 ]; then
    _log_err "release resolver exited $rc"
    printf 'release: failed (exit %d)\n' "$rc"
    RELEASE_OUTCOME="failed"
    RELEASE_REASON="release resolver exited non-zero (exit $rc)"
    RELEASE_VERSION=""
    return 1
  fi

  # Parse key=value pairs from resolver output.
  local strategy="" bump="" version="" message=""
  while IFS='=' read -r key val; do
    case "$key" in
      strategy) strategy="$val" ;;
      bump)     bump="$val" ;;
      version)  version="$val" ;;
      message)  message="$val" ;;
    esac
  done <<< "$release_output"

  # Determine the bump spec for version-bump.
  local bump_spec=""
  case "$strategy" in
    conventional-commits)
      if [ "$bump" = "none" ] || [ -z "$bump" ]; then
        _log_info "no releasable changes (bump=none)"
        printf 'release: failed (no releasable changes)\n'
        RELEASE_OUTCOME="failed"
        RELEASE_REASON="${message:-no releasable changes}"
        RELEASE_VERSION=""
        return 1
      fi
      bump_spec="$bump"
      ;;
    calendar)
      if [ -n "$version" ]; then
        bump_spec="$version"
      else
        _log_err "calendar strategy produced no version"
        RELEASE_OUTCOME="failed"
        RELEASE_REASON="calendar strategy produced no version"
        RELEASE_VERSION=""
        return 1
      fi
      ;;
    manual)
      _log_err "manual strategy requires interactive input — unsupported in trigger mode"
      RELEASE_OUTCOME="failed"
      RELEASE_REASON="manual strategy unsupported in automated trigger"
      RELEASE_VERSION=""
      return 1
      ;;
    *)
      _log_err "unknown release strategy: $strategy"
      RELEASE_OUTCOME="failed"
      RELEASE_REASON="unknown release strategy: $strategy"
      RELEASE_VERSION=""
      return 1
      ;;
  esac

  # Invoke version-bump to apply the version.
  local vb_output vb_rc=0
  if [[ "$VERSION_BUMP_BIN" == *.js ]]; then
    vb_output="$(node "$VERSION_BUMP_BIN" "$bump_spec" --config "$CONFIG_PATH" --project-root "$PROJECT_ROOT" 2>&1)" || vb_rc=$?
  else
    vb_output="$("$VERSION_BUMP_BIN" "$bump_spec" --config "$CONFIG_PATH" --project-root "$PROJECT_ROOT" 2>&1)" || vb_rc=$?
  fi

  if [ "$vb_rc" -ne 0 ]; then
    _log_err "version-bump exited $vb_rc"
    printf 'release: failed (version-bump exit %d)\n' "$vb_rc"
    RELEASE_OUTCOME="failed"
    RELEASE_REASON="version-bump exited non-zero (exit $vb_rc)"
    RELEASE_VERSION=""
    return 1
  fi

  # Extract new_version from version-bump JSON output.
  local new_version=""
  new_version="$(printf '%s' "$vb_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('new_version', ''))
except:
    pass
" 2>/dev/null || true)"

  # Fallback: use the bump_spec as the version (for calendar strategy).
  if [ -z "$new_version" ]; then
    new_version="$bump_spec"
  fi

  printf 'release: invoked strategy=%s version=%s\n' "$strategy" "$new_version"
  RELEASE_OUTCOME="success"
  RELEASE_REASON=""
  RELEASE_VERSION="$new_version"
  return 0
}

# ---------------------------------------------------------------------------
# Phase 2: Resolve affected set + deploy per environment
# ---------------------------------------------------------------------------

run_deploy() {
  _log_info "phase 2: deploy"

  # Resolve affected components.
  local affected_output
  affected_output="$("$AFFECTED_SET_BIN" --config "$CONFIG_PATH" 2>&1)" || true

  # Parse stacks from the JSON output.
  local stacks_json
  stacks_json="$(printf '%s' "$affected_output" | grep '^{' | tail -1)"

  if [ -z "$stacks_json" ]; then
    _log_err "affected-set resolver produced no output"
    return 1
  fi

  # Extract the stacks array.
  local -a components=()
  local is_wildcard=false

  while IFS= read -r stack_name; do
    [ -n "$stack_name" ] && components+=("$stack_name")
  done < <(printf '%s' "$stacks_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('stacks', []):
    print(s)
" 2>/dev/null || true)

  # Check for wildcard — expand to all stacks from config.
  if [ "${#components[@]}" -eq 1 ] && [ "${components[0]}" = "*" ]; then
    is_wildcard=true
    components=()
    while IFS= read -r stack_name; do
      [ -n "$stack_name" ] && components+=("$stack_name")
    done < <(_read_stack_names "$CONFIG_PATH")
    _log_info "wildcard affected-set expanded to: ${components[*]}"
  fi

  if [ "${#components[@]}" -eq 0 ]; then
    _log_info "no affected components — skipping deploy"
    return 0
  fi

  # Build comma-separated component list.
  local component_list=""
  local first=true
  for comp in "${components[@]}"; do
    $first || component_list+=","
    component_list+="$comp"
    first=false
  done

  # Read promotion chain environments.
  local -a envs=()
  while IFS= read -r env_id; do
    [ -n "$env_id" ] && envs+=("$env_id")
  done < <(_read_promotion_chain_ids "$CONFIG_PATH")

  if [ "${#envs[@]}" -eq 0 ]; then
    _log_err "no environments found in ci_cd.promotion_chain"
    return 1
  fi

  # Deploy to each environment. Evidence is written per-env under the
  # project root so deploy-dispatch.sh (which requires --output-dir) has
  # a writable destination. The directory is created per invocation and
  # cleaned up by the caller or CI. GAIA_DEPLOY_EVIDENCE_DIR can override
  # the base location for testing.
  local evidence_base="${GAIA_DEPLOY_EVIDENCE_DIR:-$PROJECT_ROOT/.gaia/evidence/deploy}"
  local deploy_failed=false
  DEPLOYMENTS="[]"

  for env_id in "${envs[@]}"; do
    local output_dir="$evidence_base/$env_id"
    mkdir -p "$output_dir"
    _log_info "deploying to $env_id: components=$component_list version=$RELEASE_VERSION"
    printf 'deploy: invoked env=%s components=%s version=%s\n' "$env_id" "$component_list" "$RELEASE_VERSION"

    local dep_rc=0
    "$DEPLOY_BIN" \
      --env "$env_id" \
      --version "$RELEASE_VERSION" \
      --output-dir "$output_dir" \
      --components "$component_list" || dep_rc=$?

    local dep_status="success"
    if [ "$dep_rc" -ne 0 ]; then
      dep_status="failed"
      deploy_failed=true
      _log_err "deploy to $env_id failed (exit $dep_rc)"
    fi

    # Accumulate deployment records via env vars (quoting-safe).
    DEPLOYMENTS="$(
      _PT_PREV="$DEPLOYMENTS" \
      _PT_ENV="$env_id" \
      _PT_COMPONENTS="$component_list" \
      _PT_STATUS="$dep_status" \
      python3 -c "
import os, json
prev = json.loads(os.environ['_PT_PREV'])
prev.append({
    'env': os.environ['_PT_ENV'],
    'components': os.environ['_PT_COMPONENTS'].split(','),
    'status': os.environ['_PT_STATUS']
})
print(json.dumps(prev))
" 2>/dev/null)"
  done

  if $deploy_failed; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Summary emitter
# ---------------------------------------------------------------------------

emit_summary() {
  local overall_status="$1"

  _PT_VERSION="${RELEASE_VERSION}" \
  _PT_OUTCOME="${RELEASE_OUTCOME}" \
  _PT_DEPLOYMENTS="${DEPLOYMENTS:-[]}" \
  _PT_OVERALL="$overall_status" \
  _PT_REASON="${RELEASE_REASON}" \
  python3 -c "
import os, json
summary = {
    'version': os.environ.get('_PT_VERSION', ''),
    'release_outcome': os.environ.get('_PT_OUTCOME', ''),
    'deployments': json.loads(os.environ.get('_PT_DEPLOYMENTS', '[]')),
    'overall_status': os.environ.get('_PT_OVERALL', '')
}
reason = os.environ.get('_PT_REASON', '')
if reason:
    summary['reason'] = reason
print(json.dumps(summary))
"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  _resolve_binaries

  # Module-level state.
  RELEASE_OUTCOME=""
  RELEASE_REASON=""
  RELEASE_VERSION=""
  DEPLOYMENTS="[]"

  # Phase 1: Release.
  local release_rc=0
  run_release || release_rc=$?

  if [ "$release_rc" -ne 0 ]; then
    # Release failed — skip deploy, emit failure summary, exit non-zero.
    emit_summary "failed"
    exit 1
  fi

  # Phase 2: Deploy.
  local deploy_rc=0
  run_deploy || deploy_rc=$?

  if [ "$deploy_rc" -ne 0 ]; then
    emit_summary "partial-failure"
    exit 1
  fi

  emit_summary "success"
  exit 0
}

# Main-guard: sourcing exposes functions without side-effects.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
