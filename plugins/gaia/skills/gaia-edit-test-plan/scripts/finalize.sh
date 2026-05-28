#!/usr/bin/env bash
# finalize.sh — /gaia-edit-test-plan skill finalize (E28-S87 + E42-S14)
#
# E42-S14 extends the bare-bones Cluster 11 finalize scaffolding with a
# 21-item post-completion checklist (7 script-verifiable + 14
# LLM-checkable) derived from the V1 edit-test-plan checklist
# reconciled with the V1 instructions per
# docs/v1-v2-command-gap-analysis.md §6.
#
# V1 source reconciliation:
#   - V1 checklist ships 11 `- [ ]` bullets under five H2 sections
#     (Edit Quality, New Test Cases, Coverage, Version History, Output
#     Verification). The story 21-item count is authoritative per
#     docs/v1-v2-command-gap-analysis.md §6 and epics-and-stories.md
#     §E42-S14.
#   - The remaining 10 items are reconciled from V1 instruction step
#     outputs (test plan loaded, highest test case ID identified,
#     existing test areas identified, change scope captured with
#     feature + FR/NFR IDs, PRD context consulted, architecture
#     context consulted, new test cases defined with required fields,
#     new test-area headers added when needed, Version History
#     section created, next-steps block populated).
#
# Responsibilities (per brief §Cluster 11 + story E42-S14):
#   1. Run the script-verifiable subset of the 21 V1 checklist items
#      against the test-plan.md artifact. Validation runs FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S13 contract; story AC5).
#
# Exit codes:
#   0 — finalize succeeded; all 7 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 11 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC3 "no artifact to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   EDITED_TEST_PLAN_ARTIFACT  Absolute path to the edited test-plan.md
#                              artifact to validate. When set, the
#                              script runs the 21-item checklist
#                              against it. When set but the file does
#                              not exist or is empty, AC3 fires — a
#                              single "no artifact to validate"
#                              violation is emitted and the script
#                              exits non-zero. When unset, the script
#                              skips the checklist (classic Cluster 11
#                              behaviour — observability still runs,
#                              exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-edit-test-plan/finalize.sh"
WORKFLOW_NAME="edit-test-plan"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact paths ----------
# EDITED_TEST_PLAN_ARTIFACT wins when set (test fixtures + explicit
# invocation). The checklist only runs when it is EXPLICITLY set.
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${EDITED_TEST_PLAN_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$EDITED_TEST_PLAN_ARTIFACT"
fi

# ---------- 1. Run the 21-item checklist ----------
VIOLATIONS=()
CHECKED=0
PASSED=0
CHECKLIST_STATUS=0

# item_check <id> <description> <boolean-result>
item_check() {
  local id="$1" desc="$2" result="$3"
  CHECKED=$((CHECKED + 1))
  if [ "$result" = "pass" ]; then
    printf '  [PASS] %s — %s\n' "$id" "$desc" >&2
    PASSED=$((PASSED + 1))
  else
    printf '  [FAIL] %s — %s\n' "$id" "$desc" >&2
    VIOLATIONS+=("$id — $desc")
  fi
}

file_nonempty() { [ -s "$1" ] && echo "pass" || echo "fail"; }
file_exists() { [ -f "$1" ] && echo "pass" || echo "fail"; }

# AF-2026-05-27-8 / Test06 F-001/F-004/F-009: heading_present() is now a single
# shared implementation (plugins/gaia/scripts/lib/heading-present.sh) with one
# uniform, permissive regex accepting optional numbered+lettered outline
# prefixes (11, 11b, 1.2.3). Previously 17 finalize.sh scripts carried THREE
# divergent inline copies, so the same heading passed one skill's check and
# failed another's. Sourced via a $0-relative path so it works whether or not
# this script defines PLUGIN_SCRIPTS_DIR.
_GAIA_HEADING_LIB="$(cd "$(dirname "$0")" && pwd)/../../../scripts/lib/heading-present.sh"
if [ -r "$_GAIA_HEADING_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_GAIA_HEADING_LIB"
else
  # Fallback inline definition (kept byte-equivalent to the shared lib) so the
  # checklist still runs if the lib is somehow unreadable.
  heading_present() {
    local f="$1" text="$2"
    if grep -Ei "^##[[:space:]]+([0-9]+[a-z]?(\.[0-9]+[a-z]?)*\.?[[:space:]]+)?${text}([[:space:]]|\$|[[:punct:]])" "$f" >/dev/null 2>&1; then
      echo "pass"
    else
      echo "fail"
    fi
  }
fi

pattern_present() {
  local f="$1" pattern="$2"
  grep -Eiq "$pattern" "$f" 2>/dev/null && echo "pass" || echo "fail"
}

# version_history_row_present <file>
# Pass when a Version History table row carries a date, a change
# description, a test-case ID, and an FR/NFR anchor. Structural proxy
# for V1 "Version note added with date, change summary, new test case
# IDs" (V1 Version History bullet).
version_history_row_present() {
  local f="$1"
  awk '
    /^##[[:space:]]+Version[[:space:]]+History/ { in_sec = 1; next }
    in_sec && /^##[[:space:]]+/ { in_sec = 0 }
    in_sec && /^\|/ && !/^\|[[:space:]]*-/ && !/Date[[:space:]]*\|/ {
      # Skip header row (contains "Date"); treat any remaining non-separator
      # row with a 4-digit year OR a YYYY-MM-DD shape as a valid row.
      if ($0 ~ /[0-9]{4}-[0-9]{2}-[0-9]{2}/ && $0 ~ /(TC-|FR-|NFR-)/) {
        print "pass"; hit = 1; exit
      }
    }
    END { if (!hit) print "fail" }
  ' "$f"
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  # AC3 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk or is empty (0 bytes).
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-edit-test-plan to produce .gaia/artifacts/test-artifacts/test-plan.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 21-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-edit-test-plan (21 items — 7 script-verifiable, 14 LLM-checkable)\n' >&2

  # --- Script-verifiable items (7) ---

  # SV-01 / V1 "Output file saved to {test_artifacts}/test-plan.md"
  item_check "SV-01" "Output file saved to .gaia/artifacts/test-artifacts/test-plan.md" \
    "$(file_exists "$ARTIFACT")"
  # SV-02 / structural — output file non-empty
  item_check "SV-02" "Output artifact is non-empty" \
    "$(file_nonempty "$ARTIFACT")"
  # SV-03 / V1 "Version note added with date, change summary, new test case IDs"
  item_check "SV-03" "Version History section present (## Version History heading)" \
    "$(heading_present "$ARTIFACT" "Version[[:space:]]+History")"
  # SV-04 / structural — Version History row with date + TC/FR/NFR anchors
  item_check "SV-04" "Version History row with date, change summary, new test case IDs, FR/NFR anchors" \
    "$(version_history_row_present "$ARTIFACT")"
  # SV-05 / V1 "Test cases assigned to correct test area/category"
  item_check "SV-05" "Test area section headers present (unit / integration / e2e / performance / security keyword)" \
    "$(pattern_present "$ARTIFACT" '^##[[:space:]]+(Unit|Integration|E2E|End-to-End|Performance|Security|Accessibility|Contract)')"
  # SV-06 / V1 "Test case IDs auto-incremented (no collisions)" structural proxy
  item_check "SV-06" "Test case ID convention followed (TC-NN / TP-NN anchors present)" \
    "$(pattern_present "$ARTIFACT" '(\bTC-[0-9]+|\bTP-[0-9]+|\bTest[[:space:]]+Case[[:space:]]+ID)')"
  # SV-07 / V1 "Validates field maps to FR/NFR IDs"
  item_check "SV-07" "Validates field maps to FR/NFR IDs (FR-* or NFR-* anchor present)" \
    "$(pattern_present "$ARTIFACT" '(FR-[0-9]+|NFR-[0-9]+|Validates[[:space:]]*:)')"

  # --- LLM-checkable items (14) ---
  printf '\n[LLM-CHECK] The following 14 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  [V1 category: Edit Quality]
  LLM-01 — Existing test cases preserved exactly
  LLM-02 — Existing test strategy and environments unchanged
  LLM-03 — New test cases follow same format as existing

  [V1 category: New Test Cases]
  LLM-04 — Test case IDs auto-incremented from highest existing (no collisions)
  LLM-05 — Each new test case has type, steps, expected results, priority
  LLM-06 — Test cases assigned to correct test area/category (semantic fit)

  [V1 category: Coverage]
  LLM-07 — Test scope section updated to reflect expanded coverage
  LLM-08 — Coverage summary updated (if present)

  [reconciled from V1 instruction step outputs]
  LLM-09 — Existing test plan loaded from .gaia/artifacts/test-artifacts/test-plan.md (Step 1 output)
  LLM-10 — Highest existing test case ID identified for auto-increment (Step 1)
  LLM-11 — Existing test areas/categories identified before editing (Step 1)
  LLM-12 — Change scope captured: feature description and FR/NFR IDs recorded (Step 2)
  LLM-13 — PRD and architecture context consulted where available (Step 2)
  LLM-14 — Next-steps block populated (traceability / ATDD recommendations) (Step 6)
EOF

  TOTAL_ITEMS=21
  LLM_ITEMS=14
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the test-plan artifact to satisfy the failed items, then rerun /gaia-edit-test-plan.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no edited test-plan artifact requested (EDITED_TEST_PLAN_ARTIFACT unset) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 6 >/dev/null 2>&1; then
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
