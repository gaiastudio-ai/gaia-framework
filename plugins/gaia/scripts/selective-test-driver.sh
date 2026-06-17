#!/usr/bin/env bash
# selective-test-driver.sh — end-to-end selective-test pipeline driver
#
# Chains the five pipeline stages in order:
#   1. detect-affected  → seed the affected-set from changed files
#   2. cross-refs-walk  → expand via transitive dependencies
#   3. reconcile-stale-graph → escalate on undeclared import edges
#   4. apply-test-policy → merge always_run set, apply trigger scope
#   5. generate-pipeline → emit GitHub Actions matrix JSON
#
# The driver handles three key flow-control paths:
#   - Empty set: detect-affected emits [] → short-circuit, emit empty matrix
#   - Selective: normal stack subset flows through all stages
#   - Escalation: any stage emits ["*"] → forward --config to generate-pipeline
#
# Stage scripts are injectable via env vars for deterministic testing:
#   DETECT_AFFECTED_BIN, CROSS_REFS_WALK_BIN, RECONCILE_STALE_GRAPH_BIN,
#   APPLY_TEST_POLICY_BIN, GENERATE_PIPELINE_BIN
#
# Usage:
#   selective-test-driver.sh --config <project-config.yaml> \
#     --trigger <pr|push|schedule> \
#     --files <f1> [f2 ...] | --files-from <path> | --event <type>
#
# Exit codes:
#   0 — success (matrix JSON on stdout)
#   1 — stage failure (HALT message on stderr)

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Resolve stage script paths (injectable for testing)
# ---------------------------------------------------------------------------
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_DETECT_AFFECTED="${DETECT_AFFECTED_BIN:-${_SCRIPT_DIR}/detect-affected.sh}"
_CROSS_REFS_WALK="${CROSS_REFS_WALK_BIN:-${_SCRIPT_DIR}/cross-refs-walk.sh}"
_RECONCILE_STALE="${RECONCILE_STALE_GRAPH_BIN:-${_SCRIPT_DIR}/reconcile-stale-graph.sh}"
_APPLY_POLICY="${APPLY_TEST_POLICY_BIN:-${_SCRIPT_DIR}/apply-test-policy.sh}"
_GENERATE_PIPELINE="${GENERATE_PIPELINE_BIN:-${_SCRIPT_DIR}/generate-pipeline.sh}"

# ---------------------------------------------------------------------------
# Internal helpers (underscore prefix — exempt from NFR-052 gate)
# ---------------------------------------------------------------------------
_log_info() {
  printf '[selective-test-driver] INFO: %s\n' "$*" >&2
}

_die() {
  printf '%s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# _is_empty_set JSON — true when the JSON array is empty: []
# ---------------------------------------------------------------------------
_is_empty_set() {
  local json="$1"
  local stripped
  stripped="$(printf '%s' "$json" | tr -d '[:space:]')"
  [[ "$stripped" == "[]" ]]
}

# ---------------------------------------------------------------------------
# _is_wildcard JSON — true when the JSON array is ["*"]
# ---------------------------------------------------------------------------
_is_wildcard() {
  local json="$1"
  local stripped
  stripped="$(printf '%s' "$json" | tr -d '[:space:]')"
  [[ "$stripped" == '["*"]' ]]
}

# ---------------------------------------------------------------------------
# usage — print help to stdout and exit 0
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  selective-test-driver.sh --config <project-config.yaml> \
    --trigger <pr|push|schedule> \
    --files <f1> [f2 ...] | --files-from <path> | --event <type>

Options:
  --config PATH         Path to project-config.yaml.
  --trigger TYPE        CI trigger type (pr|push|schedule).
  --files f1 [f2 ...]   Changed file paths.
  --files-from PATH     File containing one changed path per line.
  --event TYPE          Event type (e.g. promotion-push).
  --help                Print this message and exit 0.

Output:
  GitHub Actions matrix JSON on stdout.
  {"include":[{"stack":"name"},...]}

Exit codes:
  0  Success (including empty-set short-circuit).
  1  Stage failure.
USAGE
}

# ---------------------------------------------------------------------------
# parse_args — populate _CONFIG, _TRIGGER, _FILES, _FILES_FROM, _EVENT
# ---------------------------------------------------------------------------
parse_args() {
  _CONFIG=""
  _TRIGGER=""
  _FILES=()
  _FILES_FROM=""
  _EVENT=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)   _CONFIG="$2"; shift 2 ;;
      --trigger)  _TRIGGER="$2"; shift 2 ;;
      --files-from) _FILES_FROM="$2"; shift 2 ;;
      --files)
        shift
        while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
          _FILES+=("$1")
          shift
        done
        ;;
      --event)    _EVENT="$2"; shift 2 ;;
      --help|-h)  usage; exit 0 ;;
      *)
        printf 'selective-test-driver.sh: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# run_stage STAGE_NAME STAGE_BIN [args...] — run a stage, fail-fast on error
#
# Captures stdout into the global _STAGE_OUTPUT variable.
# On non-zero exit, emits HALT to stderr and exits 1.
# ---------------------------------------------------------------------------
run_stage() {
  local stage_name="$1"; shift
  local stage_bin="$1"; shift

  _log_info "running $stage_name"

  local stdout_file stderr_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"

  local exit_code=0
  "$stage_bin" "$@" > "$stdout_file" 2>"$stderr_file" || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    # Forward the stage's stderr before the HALT line
    cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    printf 'HALT: %s failed (exit %d)\n' "$stage_name" "$exit_code" >&2
    exit 1
  fi

  # Forward any stage stderr (warnings, verbose output) to our stderr
  if [[ -s "$stderr_file" ]]; then
    cat "$stderr_file" >&2
  fi

  _STAGE_OUTPUT="$(cat "$stdout_file")"
  rm -f "$stdout_file" "$stderr_file"
}

# ---------------------------------------------------------------------------
# run_pipeline — orchestrate the five-stage chain
# ---------------------------------------------------------------------------
run_pipeline() {
  # --- Build detect-affected args ----------------------------------------
  local -a detect_args=()
  [[ -n "$_CONFIG" ]] && detect_args+=(--config "$_CONFIG")
  [[ -n "$_EVENT" ]]  && detect_args+=(--event "$_EVENT")
  [[ -n "$_FILES_FROM" ]] && detect_args+=(--files-from "$_FILES_FROM")
  if [[ ${#_FILES[@]} -gt 0 ]]; then
    detect_args+=(--files "${_FILES[@]}")
  fi

  # --- Stage 1: detect-affected ------------------------------------------
  run_stage "detect-affected" "$_DETECT_AFFECTED" "${detect_args[@]}"
  local affected_set="$_STAGE_OUTPUT"

  _log_info "detect-affected output: $affected_set"

  # --- Empty-set short-circuit (docs-only change) -------------------------
  if _is_empty_set "$affected_set"; then
    _log_info "empty affected set — short-circuiting with empty matrix"
    printf '{"include":[]}\n'
    return 0
  fi

  # --- Stage 2: cross-refs-walk -------------------------------------------
  local -a cross_args=(--stacks "$affected_set")
  [[ -n "$_CONFIG" ]] && cross_args+=(--config "$_CONFIG")

  run_stage "cross-refs-walk" "$_CROSS_REFS_WALK" "${cross_args[@]}"
  affected_set="$_STAGE_OUTPUT"

  _log_info "cross-refs-walk output: $affected_set"

  # --- Stage 3: reconcile-stale-graph -------------------------------------
  local -a reconcile_args=(--affected-set "$affected_set")
  [[ -n "$_CONFIG" ]] && reconcile_args+=(--config "$_CONFIG")

  run_stage "reconcile-stale-graph" "$_RECONCILE_STALE" "${reconcile_args[@]}"
  affected_set="$_STAGE_OUTPUT"

  _log_info "reconcile-stale-graph output: $affected_set"

  # --- Stage 4: apply-test-policy -----------------------------------------
  local -a policy_args=(--affected-set "$affected_set")
  [[ -n "$_CONFIG" ]]  && policy_args+=(--config "$_CONFIG")
  [[ -n "$_TRIGGER" ]] && policy_args+=(--trigger "$_TRIGGER")

  run_stage "apply-test-policy" "$_APPLY_POLICY" "${policy_args[@]}"
  affected_set="$_STAGE_OUTPUT"

  _log_info "apply-test-policy output: $affected_set"

  # --- Stage 5: generate-pipeline -----------------------------------------
  local -a gen_args=(--affected-set "$affected_set")
  # Forward --config when the set is ["*"] so generate-pipeline can resolve
  # all stack names from the config file.
  if _is_wildcard "$affected_set"; then
    if [[ -n "$_CONFIG" ]]; then
      gen_args+=(--config "$_CONFIG")
    fi
  fi

  run_stage "generate-pipeline" "$_GENERATE_PIPELINE" "${gen_args[@]}"
  local matrix_json="$_STAGE_OUTPUT"

  # Emit the final matrix JSON on stdout
  printf '%s\n' "$matrix_json"
}

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  run_pipeline
}

# Main-guard: only invoke main when executed directly (not when sourced).
# Required for NFR-052 — sourcing must expose public functions without side-effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
