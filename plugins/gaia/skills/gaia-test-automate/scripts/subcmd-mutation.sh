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
#   subcmd-mutation.sh <story_key> [--config <yaml>] [--project-root <dir>]
#                      [--evidence-dir <dir>] [--worktree <dir>]
#                      [--timeout <seconds>]
#
# --timeout is the limit for one test run under one interpreter. Without it the
# runner uses $GAIA_MUTATION_TIMEOUT, then the adapter's default.
#
# Exit codes:
#   0  Evidence written with gate passed, failed, advisory or not_applicable, or
#      thresholds are not configured
#   1  The run could not produce a usable gate (blocking_failure:
#      runner_unavailable): runner failure, unreadable config, or evidence with
#      gate errored
#
# POSIX discipline: bash 3.2, no local -A, no mapfile.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="subcmd-mutation.sh"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"
PLUGIN_SCRIPTS="$(CDPATH='' cd -- "$SCRIPT_DIR/../../.." >/dev/null && pwd)/scripts"

# shellcheck source=../../../scripts/lib/mutation-config.sh
. "$PLUGIN_SCRIPTS/lib/mutation-config.sh"

_sm_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_sm_die() { local rc="$1"; shift; _sm_err "$*"; exit "$rc"; }
_sm_info() { printf '%s: INFO: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---------- Arg parsing ----------
_sm_story_key="${1:-}"
shift || true
_sm_config=""
_sm_evidence_dir=""
_sm_worktree=""
_sm_timeout_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config)       _sm_config="${2:-}"; shift 2 ;;
    --project-root) PROJECT_ROOT="${2:-}"; export PROJECT_ROOT; shift 2 ;;
    --evidence-dir) _sm_evidence_dir="${2:-}"; shift 2 ;;
    --worktree)     _sm_worktree="${2:-}"; shift 2 ;;
    --timeout)      _sm_timeout_args=(--timeout "${2:-}"); shift 2 ;;
    *)              _sm_die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$_sm_story_key" ] || _sm_die 1 "story_key is required"

# ---------- Resolve paths ----------
_sm_worktree="${_sm_worktree:-${PROJECT_PATH:-${PROJECT_ROOT:-$(pwd)}}}"

if [ -z "$_sm_config" ]; then
  _sm_config="$(mutation_config_path)"
fi

# ---------- Check thresholds ----------
_sm_thresholds=""
if [ -n "$_sm_config" ]; then
  _sm_thresholds="$(mutation_read_thresholds "$_sm_config")" \
    || _sm_die 1 "cannot read mutation thresholds; blocking_failure: runner_unavailable"
fi

if [ -z "$_sm_thresholds" ]; then
  _sm_info "mutation_thresholds not configured; skipping mutation run"
  exit 0
fi

# Same directory as the execution evidence; the path helper is what the review
# consumers read through.
if [ -n "$_sm_evidence_dir" ]; then
  _sm_output="${_sm_evidence_dir%/}/${_sm_story_key}-mutation.json"
else
  _sm_output="$(mutation_evidence_path "$_sm_story_key")"
fi
mkdir -p "$(dirname "$_sm_output")"

# ---------- Run mutation runner wrapped in heavy-reviewer slots ----------
_sm_info "running mutation analysis for $_sm_story_key"

_sm_runner="$PLUGIN_SCRIPTS/mutation-runner.sh"
[ -x "$_sm_runner" ] || _sm_die 1 "mutation-runner.sh not found at $_sm_runner"
_sm_hrs="$PLUGIN_SCRIPTS/lib/heavy-reviewer-slots.sh"
[ -f "$_sm_hrs" ] || _sm_die 1 "heavy-reviewer-slots.sh not found at $_sm_hrs"

bash "$_sm_hrs" run -- "$_sm_runner" \
  --story "$_sm_story_key" \
  --worktree "$_sm_worktree" \
  --output "$_sm_output" \
  --patch-dir "$(dirname "$_sm_output")/${_sm_story_key}-mutants" \
  --thresholds "$_sm_thresholds" \
  ${_sm_timeout_args[@]+"${_sm_timeout_args[@]}"} \
  || _sm_die 1 "mutation runner failed; blocking_failure: runner_unavailable"

_sm_gate="$(jq -r '.gate // "errored"' "$_sm_output")"
_sm_info "mutation evidence written to $_sm_output (gate: $_sm_gate)"
if [ "$_sm_gate" = "errored" ]; then
  _sm_die 1 "the run produced no usable gate: $(jq -r '.refused // "see the messages above and the evidence file"' "$_sm_output"); blocking_failure: runner_unavailable"
fi
exit 0
