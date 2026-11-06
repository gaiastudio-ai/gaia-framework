#!/usr/bin/env bash
# subcmd-mutation.sh — /gaia-test-automate --mutation subcommand.
#
# Runs the mutation runner for a single story, wrapped in the heavy-reviewer
# slot semaphore. Writes evidence next to the story's execution evidence.
#
# This is the sole producer of mutation evidence. Review consumers (QA,
# test-review) read the evidence but never invoke the runner themselves.
#
# Usage:
#   subcmd-mutation.sh <story_key> [--config <yaml>]
#
# Exit codes:
#   0  Evidence written (gate may be any value)
#   1  Runner error (no evidence written; blocking_failure: runner_unavailable)
#
# POSIX discipline: bash 3.2, no local -A, no mapfile.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="subcmd-mutation.sh"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"
PLUGIN_SCRIPTS="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." >/dev/null && pwd)/scripts"

_sm_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_sm_die() { local rc="$1"; shift; _sm_err "$*"; exit "$rc"; }
_sm_info() { printf '%s: INFO: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---------- Arg parsing ----------
_sm_story_key="${1:-}"
shift || true
_sm_config=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config) shift; _sm_config="${1:-}"; shift ;;
    *)        shift ;;
  esac
done

[ -n "$_sm_story_key" ] || _sm_die 1 "story_key is required"

# ---------- Resolve paths ----------
_sm_worktree="${PROJECT_PATH:-$(pwd)}"

# Resolve story file
_sm_story_file=""
if [ -x "$PLUGIN_SCRIPTS/resolve-story-file.sh" ]; then
  _sm_story_file=$("$PLUGIN_SCRIPTS/resolve-story-file.sh" "$_sm_story_key" 2>/dev/null || true)
fi

# Resolve test-artifacts path
_sm_test_artifacts=""
if [ -x "$PLUGIN_SCRIPTS/resolve-config.sh" ]; then
  _sm_test_artifacts=$("$PLUGIN_SCRIPTS/resolve-config.sh" --field test_artifacts 2>/dev/null || true)
fi
if [ -z "$_sm_test_artifacts" ]; then
  _sm_test_artifacts="${_sm_worktree}/.gaia/artifacts/test-artifacts"
fi

# Evidence output path (same directory as execution evidence)
_sm_evidence_dir="$_sm_test_artifacts/test-results"
mkdir -p "$_sm_evidence_dir"
_sm_output="$_sm_evidence_dir/${_sm_story_key}-mutation.json"

# ---------- Resolve config ----------
if [ -z "$_sm_config" ]; then
  # Try standard locations
  for candidate in \
    "${_sm_worktree}/.gaia/config/project-config.yaml" \
    "${CLAUDE_PROJECT_ROOT:-.}/.gaia/config/project-config.yaml"; do
    if [ -f "$candidate" ]; then
      _sm_config="$candidate"
      break
    fi
  done
fi

# ---------- Check thresholds ----------
_sm_thresholds=""
if [ -n "$_sm_config" ] && [ -f "$_sm_config" ]; then
  # Check if the key is present in the config
  _sm_has_key=0
  if grep -q 'mutation_thresholds' "$_sm_config" 2>/dev/null; then
    _sm_has_key=1
  fi

  if ! command -v yq >/dev/null 2>&1; then
    if [ "$_sm_has_key" -eq 1 ]; then
      _sm_die 1 "yq is required to read mutation_thresholds from project config but is not installed"
    fi
  else
    _sm_thresholds=$(yq -o=json '.test_execution.mutation_thresholds // empty' "$_sm_config" 2>/dev/null || true)
    if [ "$_sm_thresholds" = "null" ] || [ -z "$_sm_thresholds" ]; then
      _sm_thresholds=""
    fi
  fi
fi

if [ -z "$_sm_thresholds" ]; then
  _sm_info "mutation_thresholds not configured; skipping mutation run"
  exit 0
fi

# ---------- Run mutation runner wrapped in heavy-reviewer slots ----------
_sm_info "running mutation analysis for $_sm_story_key"

_sm_runner="$PLUGIN_SCRIPTS/mutation-runner.sh"
[ -x "$_sm_runner" ] || _sm_die 1 "mutation-runner.sh not found at $_sm_runner"

_sm_runner_args=(
  --story "$_sm_story_key"
  --worktree "$_sm_worktree"
  --output "$_sm_output"
  --thresholds "$_sm_thresholds"
)

if [ -n "$_sm_config" ]; then
  _sm_runner_args+=(--config "$_sm_config")
fi

# Wrap in heavy-reviewer-slots if available
_sm_hrs="$PLUGIN_SCRIPTS/lib/heavy-reviewer-slots.sh"
if [ -x "$_sm_hrs" ]; then
  "$_sm_hrs" run -- "$_sm_runner" "${_sm_runner_args[@]}"
else
  "$_sm_runner" "${_sm_runner_args[@]}"
fi

_sm_info "mutation evidence written to $_sm_output"
exit 0
