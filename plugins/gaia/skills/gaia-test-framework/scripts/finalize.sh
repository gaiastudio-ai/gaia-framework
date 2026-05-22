#!/usr/bin/env bash
# finalize.sh — /gaia-test-framework skill finalize (E28-S87 + E42-S15)
#
# E42-S15 extends the bare-bones Cluster 11 finalize scaffolding with a
# 7-item post-completion checklist (4 script-verifiable + 3
# LLM-checkable) derived from the V1 test-framework checklist (see the
# docs/v1-v2-command-gap-analysis.md entry for the verbatim V1 source).
# See .gaia/artifacts/implementation-artifacts/E42-S15-* for the V1 → V2 mapping.
#
# Responsibilities (per brief §Cluster 11 + story E42-S15):
#   1. Run the script-verifiable subset of the 7 V1 checklist items
#      against the test-framework-setup.md artifact. Validation runs
#      FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S14 contract; story AC6).
#
# Exit codes:
#   0 — finalize succeeded; all 4 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 11 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC4 "no artifact to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   TEST_FRAMEWORK_SETUP_ARTIFACT  Absolute path to the test-framework-setup.md
#                                  artifact to validate. When set, the
#                                  script runs the 7-item checklist
#                                  against it. When set but the file
#                                  does not exist or is empty, AC4
#                                  fires — a single "no artifact to
#                                  validate" violation is emitted and
#                                  the script exits non-zero. When
#                                  unset, the script skips the
#                                  checklist (classic Cluster 11
#                                  behaviour — observability still
#                                  runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-framework/finalize.sh"
WORKFLOW_NAME="test-framework"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact paths ----------
# TEST_FRAMEWORK_SETUP_ARTIFACT wins when set (test fixtures + explicit
# invocation). The checklist only runs when it is EXPLICITLY set.
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${TEST_FRAMEWORK_SETUP_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$TEST_FRAMEWORK_SETUP_ARTIFACT"
fi

# ---------- 1. Run the 7-item checklist ----------
VIOLATIONS=()
CHECKED=0
PASSED=0
CHECKLIST_STATUS=0

# item_check <id> <description> <boolean-result>
item_check() {
  local id="$1" desc="$2" result="$3"
  CHECKED=$((CHECKED + 1))
  if [ "$result" = "pass" ]; then
    printf '  [PASS] %s — %s [skill: test-framework]\n' "$id" "$desc" >&2
    PASSED=$((PASSED + 1))
  else
    printf '  [FAIL] %s — %s [skill: test-framework]\n' "$id" "$desc" >&2
    VIOLATIONS+=("$id — $desc")
  fi
}

pattern_present() {
  local f="$1" pattern="$2"
  grep -Eiq "$pattern" "$f" 2>/dev/null && echo "pass" || echo "fail"
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  # AC4 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk or is empty (0 bytes).
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-test-framework to produce .gaia/artifacts/test-artifacts/test-framework-setup.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 7-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-test-framework (7 items — 4 script-verifiable, 3 LLM-checkable)\n' >&2

  # --- Script-verifiable items (4) ---

  # SV-01 / V1 "Config files generated"
  item_check "SV-01" "Config files generated" \
    "$(pattern_present "$ARTIFACT" '(^##[[:space:]]+Config[[:space:]]+Files|vitest\.config|jest\.config|pytest\.ini|playwright\.config|junit|build\.gradle|pubspec\.yaml|go\.mod|config[[:space:]]+files[[:space:]]+(generated|created))')"
  # SV-02 / V1 "Folder structure scaffolded"
  item_check "SV-02" "Folder structure scaffolded" \
    "$(pattern_present "$ARTIFACT" '(^##[[:space:]]+Folder[[:space:]]+Structure|tests/unit|tests/integration|tests/e2e|test/[[:alnum:]]+/|folder[[:space:]]+structure[[:space:]]+scaffold)')"
  # SV-03 / V1 "Test runner script configured and executable (e.g., npm test)"
  item_check "SV-03" "Test runner script configured and executable" \
    "$(pattern_present "$ARTIFACT" '(^##[[:space:]]+Test[[:space:]]+Runner|npm[[:space:]]+test|yarn[[:space:]]+test|pytest|gradle[[:space:]]+test|mvn[[:space:]]+test|flutter[[:space:]]+test|go[[:space:]]+test|test[[:space:]]+runner[[:space:]]+(script|configured))')"
  # SV-04 / V1 "Fixture architecture designed"
  item_check "SV-04" "Fixture architecture designed" \
    "$(pattern_present "$ARTIFACT" '(^##[[:space:]]+Fixture[[:space:]]+Architecture|fixture[[:space:]]+(architecture|pattern|design)|factory[[:space:]]+(pattern|function)|builder[[:space:]]+pattern)')"

  # --- LLM-checkable items (3) ---
  printf '\n[LLM-CHECK] The following 3 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Project stack detected correctly
  LLM-02 — Framework recommendation matches stack
  LLM-03 — No actual test implementations created — tests are written in Phase 4
EOF

  TOTAL_ITEMS=7
  LLM_ITEMS=3
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the test-framework-setup artifact to satisfy the failed items, then rerun /gaia-test-framework.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no test-framework-setup artifact requested (TEST_FRAMEWORK_SETUP_ARTIFACT unset) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 5 >/dev/null 2>&1; then
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
