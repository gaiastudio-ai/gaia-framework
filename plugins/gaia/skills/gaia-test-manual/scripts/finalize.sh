#!/usr/bin/env bash
# finalize.sh — test-manual skill finalize
#
# Responsibilities:
#   1. Write a checkpoint via the shared checkpoint.sh foundation script
#   2. Emit a lifecycle event via lifecycle-event.sh for the tailing sync agent
#   3. Record the manual-test verdict on the review-gate extended ledger
#   4. Append a row to the persistent verdicts TSV for flakiness tracking
#
# Exit codes:
#   0 — finalize succeeded
#   1 — checkpoint write or lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-manual/finalize.sh"
WORKFLOW_NAME="test-manual"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"
REVIEW_GATE="$PLUGIN_SCRIPTS_DIR/review-gate.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 5 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

# ---------- 2. Emit lifecycle event ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    die "lifecycle-event.sh emit failed for $WORKFLOW_NAME"
  fi
  log "lifecycle event emitted for $WORKFLOW_NAME"
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event emission (non-fatal)"
fi

# ---------- 3. Record manual-test verdict on the review-gate ledger ----------
# Uses the same plan-id-keyed extended ledger tier as test-automate-plan and
# story-validation. The verdict and story key are passed via env vars set by
# the orchestrating SKILL.md step.
_mt_verdict="${MANUAL_TEST_VERDICT:-}"
_mt_story="${MANUAL_TEST_STORY_KEY:-}"
_mt_run_id="${MANUAL_TEST_RUN_ID:-manual-test-$(date +%Y%m%d%H%M%S)}"

if [ -n "$_mt_verdict" ] && [ -n "$_mt_story" ] && [ -x "$REVIEW_GATE" ]; then
  _mt_reason="${MANUAL_TEST_REPORT_MISSING_REASON:-manual-test evidence recorded separately}"
  if bash "$REVIEW_GATE" update \
       --story "$_mt_story" \
       --gate "manual-test" \
       --plan-id "$_mt_run_id" \
       --verdict "$_mt_verdict" \
       --report-missing-reason "$_mt_reason" 2>/dev/null; then
    log "manual-test verdict $_mt_verdict recorded on ledger for $_mt_story (run: $_mt_run_id)"
  else
    log "WARNING: failed to record manual-test verdict on ledger (non-fatal)"
  fi
else
  if [ -z "$_mt_verdict" ] || [ -z "$_mt_story" ]; then
    log "manual-test verdict recording skipped (MANUAL_TEST_VERDICT or MANUAL_TEST_STORY_KEY not set)"
  fi
fi

# ---------- 4. Append to persistent verdicts TSV for flakiness tracking ----------
if [ -n "$_mt_verdict" ] && [ -n "$_mt_story" ]; then
  _tsv_path="${MANUAL_TEST_VERDICTS_TSV:-}"
  if [ -z "$_tsv_path" ]; then
    _root="${PROJECT_PATH:-.}"
    _tsv_path="$_root/.gaia/state/manual-test-verdicts.tsv"
  fi
  _tsv_dir="$(dirname "$_tsv_path")"
  mkdir -p "$_tsv_dir" 2>/dev/null || true
  _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\t%s\t%s\n' "$_mt_story" "$_mt_run_id" "$_mt_verdict" "$_ts" >> "$_tsv_path"
  log "verdict row appended to $_tsv_path"
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
