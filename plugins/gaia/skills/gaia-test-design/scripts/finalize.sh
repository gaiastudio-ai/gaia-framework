#!/usr/bin/env bash
# finalize.sh — /gaia-test-design skill finalize (E28-S82 + E42-S14)
#
# E42-S14 extends the bare-bones Cluster 11 finalize scaffolding with an
# 8-item post-completion checklist (6 script-verifiable + 2 LLM-checkable)
# derived from the V1 test-design checklist (see the
# docs/v1-v2-command-gap-analysis.md §5 entry for the verbatim V1 source).
# See .gaia/artifacts/implementation-artifacts/E42-S14-* for the V1 → V2 mapping.
#
# Responsibilities (per brief §Cluster 11 + story E42-S14):
#   1. Run the script-verifiable subset of the 8 V1 checklist items
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
#   0 — finalize succeeded; all 6 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 11 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC3 "no artifact to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   TEST_PLAN_ARTIFACT  Absolute path to the test-plan.md artifact to
#                       validate. When set, the script runs the 8-item
#                       checklist against it. When set but the file does
#                       not exist or is empty, AC3 fires — a single "no
#                       artifact to validate" violation is emitted and
#                       the script exits non-zero. When unset, the
#                       script looks for .gaia/artifacts/test-artifacts/test-plan.md
#                       relative to the current working directory. If
#                       neither is present, the checklist run is skipped
#                       (classic Cluster 11 behaviour — observability
#                       still runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-design/finalize.sh"
WORKFLOW_NAME="test-design"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact paths ----------
# TEST_PLAN_ARTIFACT wins when set (test fixtures + explicit invocation).
# The checklist only runs when TEST_PLAN_ARTIFACT is EXPLICITLY set —
# we do NOT auto-pick up .gaia/artifacts/test-artifacts/test-plan.md on disk,
# because the audit-v2-migration harness (enriched fixture mode) may
# pre-create a placeholder test-plan.md to satisfy downstream skills'
# validate-gate.sh probes. Auto-validating that placeholder would be a
# false-positive regression. Interactive /gaia-test-design runs that
# want validation set TEST_PLAN_ARTIFACT explicitly via orchestrator
# wiring.
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${TEST_PLAN_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$TEST_PLAN_ARTIFACT"
fi

# ---------- 1. Run the 8-item checklist ----------
VIOLATIONS=()
CHECKED=0
PASSED=0
CHECKLIST_STATUS=0

# item_check <id> <description> <boolean-result>
# boolean-result: "pass" or "fail".
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

# heading_present <file> <heading-regex>
# Pass when an H2 heading matching the pattern exists.
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

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  # AC3 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk or is empty (0 bytes).
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-test-design to produce .gaia/artifacts/test-artifacts/test-plan.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 8-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-test-design (8 items — 6 script-verifiable, 2 LLM-checkable)\n' >&2

  # --- Script-verifiable items (6) ---

  # SV-01 / V1 "Output file saved to {test_artifacts}/test-plan.md"
  item_check "SV-01" "Output file saved to .gaia/artifacts/test-artifacts/test-plan.md" \
    "$(file_exists "$ARTIFACT")"
  # SV-02 / structural — output file non-empty
  item_check "SV-02" "Output artifact is non-empty" \
    "$(file_nonempty "$ARTIFACT")"
  # SV-03 / V1 "Risk assessment completed with probability x impact ratings"
  item_check "SV-03" "Risk assessment section present (risk heading + probability/impact keywords)" \
    "$(if [ "$(heading_present "$ARTIFACT" "Risk")" = "pass" ] && [ "$(pattern_present "$ARTIFACT" '(probability|impact)')" = "pass" ]; then echo pass; else echo fail; fi)"
  # SV-04 / V1 "Test levels defined per component" + "Test pyramid applied appropriately"
  item_check "SV-04" "Test strategy section present (test pyramid / test levels keyword)" \
    "$(pattern_present "$ARTIFACT" '(test[[:space:]]+pyramid|test[[:space:]]+levels?|unit|integration|e2e|end-to-end)')"
  # SV-05 / V1 "Coverage targets defined"
  item_check "SV-05" "Coverage targets defined (coverage / target keyword present)" \
    "$(pattern_present "$ARTIFACT" '(coverage[[:space:]]+target|coverage[[:space:]]+(threshold|goal|percent)|%[[:space:]]*coverage)')"
  # SV-06 / V1 "Quality gates specified for CI"
  item_check "SV-06" "Quality gates specified for CI (quality gate / CI gate keyword present)" \
    "$(pattern_present "$ARTIFACT" '(quality[[:space:]]+gate|CI[[:space:]]+gate|ci[[:space:]]+pipeline|gate[[:space:]]+failure)')"

  # --- LLM-checkable items (2) ---
  printf '\n[LLM-CHECK] The following 2 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Legacy integration boundaries identified and tested (if brownfield)
  LLM-02 — Data migration validation tests defined (if applicable)
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
    printf 'Remediation: amend the test-plan artifact to satisfy the failed items, then rerun /gaia-test-design.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no test-plan artifact requested (TEST_PLAN_ARTIFACT unset) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 8 >/dev/null 2>&1; then
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
