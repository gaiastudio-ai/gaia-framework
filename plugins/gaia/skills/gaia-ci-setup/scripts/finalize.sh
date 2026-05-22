#!/usr/bin/env bash
# finalize.sh — /gaia-ci-setup skill finalize (E28-S86 + E28-S199 + E42-S15)
#
# E42-S15 extends the bare-bones Cluster 11 finalize scaffolding with an
# 8-item post-completion checklist (6 script-verifiable + 2
# LLM-checkable) derived from the V1 ci-setup checklist (see the
# docs/v1-v2-command-gap-analysis.md entry for the verbatim V1 source).
# See .gaia/artifacts/implementation-artifacts/E42-S15-* for the V1 → V2 mapping.
#
# E28-S199 history: the unconditional `validate-gate.sh ci_setup_exists`
# post-check was removed because this skill IS the producer of
# .gaia/artifacts/test-artifacts/ci-setup.md; a post-check on the producer's own
# output is tautological. That removal stands; E42-S15 only adds the
# V1 checklist port on top of the post-S199 baseline.
#
# Responsibilities (per brief §Cluster 11 + story E42-S15):
#   1. Run the script-verifiable subset of the 8 V1 checklist items
#      against the ci-setup.md artifact. Validation runs FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S14 contract; story AC6).
#
# Exit codes:
#   0 — finalize succeeded; all 6 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 11 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC4 "no artifact to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   CI_SETUP_ARTIFACT  Absolute path to the ci-setup.md artifact to
#                      validate. When set, the script runs the 8-item
#                      checklist against it. When set but the file
#                      does not exist or is empty, AC4 fires — a
#                      single "no artifact to validate" violation is
#                      emitted and the script exits non-zero. When
#                      unset, the script skips the checklist (classic
#                      Cluster 11 behaviour — observability still
#                      runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-ci-setup/finalize.sh"
WORKFLOW_NAME="ci-setup"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact paths ----------
# CI_SETUP_ARTIFACT wins when set (test fixtures + explicit invocation).
# The checklist only runs when it is EXPLICITLY set.
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${CI_SETUP_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$CI_SETUP_ARTIFACT"
fi

# ---------- 1. Run the 8-item checklist ----------
VIOLATIONS=()
CHECKED=0
PASSED=0
CHECKLIST_STATUS=0

# item_check <id> <description> <boolean-result>
item_check() {
  local id="$1" desc="$2" result="$3"
  CHECKED=$((CHECKED + 1))
  if [ "$result" = "pass" ]; then
    printf '  [PASS] %s — %s [skill: ci-setup]\n' "$id" "$desc" >&2
    PASSED=$((PASSED + 1))
  else
    printf '  [FAIL] %s — %s [skill: ci-setup]\n' "$id" "$desc" >&2
    VIOLATIONS+=("$id — $desc")
  fi
}

heading_present() {
  local f="$1" text="$2"
  if grep -Eiq "^##[[:space:]]+${text}([[:space:]]|\$|[[:punct:]])" "$f" 2>/dev/null; then
    echo "pass"
  else
    echo "fail"
  fi
}

pattern_present() {
  local f="$1" pattern="$2"
  grep -Eiq "$pattern" "$f" 2>/dev/null && echo "pass" || echo "fail"
}

# pipeline_stages_present <file>
# Pass when "build", "lint", "test", and "coverage" stage tokens appear
# (case-insensitive) under any heading. V1 item: "Pipeline stages
# defined (build, lint, test, coverage)".
pipeline_stages_present() {
  local f="$1"
  for stage in build lint test coverage; do
    if ! grep -Eiq "(^|[^a-z])${stage}([^a-z]|\$)" "$f" 2>/dev/null; then
      echo "fail"
      return
    fi
  done
  echo "pass"
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  # AC4 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk or is empty (0 bytes).
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-ci-setup to produce .gaia/artifacts/test-artifacts/ci-setup.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 8-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-ci-setup (8 items — 6 script-verifiable, 2 LLM-checkable)\n' >&2

  # --- Script-verifiable items (6) ---

  # SV-01 / V1 "Pipeline stages defined (build, lint, test, coverage)"
  item_check "SV-01" "Pipeline stages defined (build, lint, test, coverage)" \
    "$(pipeline_stages_present "$ARTIFACT")"
  # SV-02 / V1 "Quality gate thresholds set"
  item_check "SV-02" "Quality gate thresholds set" \
    "$(pattern_present "$ARTIFACT" '(threshold|coverage[[:space:]]+(target|percent|%)|pass[[:space:]]+rate|gate[[:space:]]+threshold)')"
  # SV-03 / V1 "Secrets management documented (required secrets, environment separation)"
  item_check "SV-03" "Secrets management documented (required secrets, environment separation)" \
    "$(heading_present "$ARTIFACT" "Secrets([[:space:]]+Management)?")"
  # SV-04 / V1 "Deployment strategy defined (staging, production, rollback)"
  item_check "SV-04" "Deployment strategy defined (staging, production, rollback)" \
    "$(if [ "$(heading_present "$ARTIFACT" "Deployment([[:space:]]+Strategy)?")" = "pass" ] \
         && [ "$(pattern_present "$ARTIFACT" 'staging')" = "pass" ] \
         && [ "$(pattern_present "$ARTIFACT" '(production|prod)')" = "pass" ] \
         && [ "$(pattern_present "$ARTIFACT" 'rollback')" = "pass" ]; then echo pass; else echo fail; fi)"
  # SV-05 / V1 "Monitoring and notifications configured (failure alerts, status badge)"
  item_check "SV-05" "Monitoring and notifications configured (failure alerts, status badge)" \
    "$(if [ "$(heading_present "$ARTIFACT" "(Monitoring([[:space:]]+and[[:space:]]+Notifications)?|Notifications)")" = "pass" ] \
         && [ "$(pattern_present "$ARTIFACT" '(alert|notification|webhook|slack|status[[:space:]]+badge|badge)')" = "pass" ]; then echo pass; else echo fail; fi)"
  # SV-06 / V1 "Pipeline config generated"
  item_check "SV-06" "Pipeline config generated" \
    "$(pattern_present "$ARTIFACT" '(^##[[:space:]]+Pipeline[[:space:]]+Config|\.github/workflows/|\.gitlab-ci\.yml|Jenkinsfile|\.circleci/config\.yml|pipeline[[:space:]]+config[[:space:]]+(generated|created))')"

  # --- LLM-checkable items (2) ---
  printf '\n[LLM-CHECK] The following 2 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — CI platform confirmed by user (not just auto-detected)
  LLM-02 — Gates are enforced (blocking, not advisory)
EOF

  TOTAL_ITEMS=8
  LLM_ITEMS=2
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the ci-setup artifact to satisfy the failed items, then rerun /gaia-ci-setup.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no ci-setup artifact requested (CI_SETUP_ARTIFACT unset) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 9 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

# ---------- 3. Emit lifecycle event (observability — never suppressed) ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    die "lifecycle-event.sh emit failed for $WORKFLOW_NAME"
  fi
  log "lifecycle event emitted for $WORKFLOW_NAME"
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event emission (non-fatal)"
fi

# ---------- 4. Auto-save session memory (E45-S3 / ADR-061) ----------
# Phase 1-3 skills auto-save a session summary to the agent sidecar via
# the shared lib helper. Phase 4 skills (e.g. /gaia-dev-story) short-
# circuit to a no-op so the interactive prompt mandated by ADR-057 /
# FR-YOLO-2(f) is preserved. Failure is non-blocking — the auto-save
# helper itself logs warnings to stderr but never affects this script's
# exit code. SKILL_NAME is resolved from the parent directory name so
# the wire-in is identical across all 24 Phase 1-3 finalize.sh files.
AUTOSAVE_LIB="$PLUGIN_SCRIPTS_DIR/lib/auto-save-memory.sh"
SKILL_NAME="$(basename "$(cd "$SCRIPT_DIR/.." && pwd)")"
if [ -f "$AUTOSAVE_LIB" ]; then
  # shellcheck disable=SC1090
  . "$AUTOSAVE_LIB"
  if ! _auto_save_memory "$SKILL_NAME" "${ARTIFACT:-}"; then
    AUTOSAVE_RC=$?
    if [ "$AUTOSAVE_RC" -eq 64 ]; then
      log "auto-save aborted: cannot resolve agent sidecar for skill $SKILL_NAME"
    fi
  fi
else
  log "auto-save-memory.sh not found at $AUTOSAVE_LIB — skipping auto-save (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit "$CHECKLIST_STATUS"
