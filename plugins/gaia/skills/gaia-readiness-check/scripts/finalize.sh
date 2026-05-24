#!/usr/bin/env bash
# finalize.sh — /gaia-readiness-check skill finalize (E28-S48 + E42-S13)
#
# E42-S13 extends the bare-bones Cluster 6 finalize scaffolding with a
# 65-item post-completion checklist (25 script-verifiable + 40
# LLM-checkable) derived from the V1 implementation-readiness checklist
# plus the reconciled items from the gap analysis (§14
# /gaia-readiness-check).
# See .gaia/artifacts/implementation-artifacts/E42-S13-* for the V1 -> V2 mapping.
#
# Responsibilities (per brief §Cluster 6 + story E42-S13):
#   1. Run the script-verifiable subset of the 65 V1 checklist items
#      against the readiness-report.md artifact. Validation runs
#      FIRST (before checkpoint/lifecycle-event — AC-EC6 ordering).
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S12 contract; story AC5).
#
# Exit codes:
#   0 — finalize succeeded; all 25 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 6 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC4 "no readiness report to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint (AC2).
#
# Environment:
#   READINESS_ARTIFACT    Absolute path to the readiness-report artifact
#                         to validate. When set, the script runs the
#                         65-item checklist against it. When set but
#                         the file does not exist or is empty, AC4
#                         fires — a single "no readiness report to
#                         validate" violation is emitted and the script
#                         exits non-zero. When unset, the script looks
#                         for .gaia/artifacts/planning-artifacts/readiness-report.md
#                         relative to the current working directory.
#                         If neither is present, the checklist run is
#                         skipped (classic Cluster 6 behaviour —
#                         observability still runs, exit 0).
#   PROJECT_ROOT          Optional. Root path used to resolve upstream
#                         artifact presence checks (PRD, architecture,
#                         test-plan, etc.). Defaults to the current
#                         working directory.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-readiness-check/finalize.sh"
WORKFLOW_NAME="implementation-readiness"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Allow override for testing
if [ -n "${PLUGIN_SCRIPTS_DIR:-}" ]; then
  : # use the override
else
  PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"
fi

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact paths ----------
# READINESS_ARTIFACT wins when set (test fixtures + explicit
# invocation). If it is set but the file is missing or empty, AC4
# fires. If unset, fall back to
# .gaia/artifacts/planning-artifacts/readiness-report.md. If neither is present
# the checklist is simply skipped (observability still runs).
# PROJECT_ROOT is used only for upstream-artifact presence checks
# (AC-EC5) against the READINESS_ARTIFACT body. Precedence:
# PROJECT_ROOT → CLAUDE_PROJECT_ROOT → $PWD. The audit-v2-migration
# harness (E28-S200) sets CLAUDE_PROJECT_ROOT; explicit bats tests set
# PROJECT_ROOT; interactive /gaia-readiness-check invocations use $PWD.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-$PWD}}"

# Resolve the artifact to validate. The checklist only runs when
# READINESS_ARTIFACT is EXPLICITLY set — we do NOT auto-pick up a
# readiness-report.md on disk, because the audit-v2-migration harness
# (enriched fixture mode) pre-creates a placeholder
# .gaia/artifacts/planning-artifacts/readiness-report.md to satisfy downstream
# skills' validate-gate.sh probes. Auto-validating that placeholder
# would be a false positive regression — the audit would record
# finalize.sh FAIL when in fact nothing asked for validation.
# Interactive /gaia-readiness-check runs that want validation set
# READINESS_ARTIFACT explicitly via the skill's orchestrator wiring.
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${READINESS_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$READINESS_ARTIFACT"
else
  # AF-2026-05-24-13 / Test02 F-35: the original strict-env-var-only
  # resolution meant interactive /gaia-readiness-check runs (without
  # READINESS_ARTIFACT explicitly exported) saw "no artifact found"
  # even when the canonical .gaia/artifacts/planning-artifacts/readiness-report.md
  # existed on disk. The audit-v2-migration harness's enriched-fixture
  # placeholder concern (above) is preserved by an opt-out signal:
  # GAIA_READINESS_FIXTURE_GUARD=1 reproduces the strict-env-var-only
  # behavior for the audit harness. The default behavior now auto-picks
  # up the canonical artifact when present, fixing the interactive UX.
  if [ "${GAIA_READINESS_FIXTURE_GUARD:-0}" != "1" ]; then
    CANONICAL_RR="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/readiness-report.md"
    LEGACY_RR="docs/planning-artifacts/readiness-report.md"
    if [ -f "$CANONICAL_RR" ] && [ -s "$CANONICAL_RR" ]; then
      ARTIFACT_REQUESTED=1
      ARTIFACT="$CANONICAL_RR"
    elif [ -f "$LEGACY_RR" ] && [ -s "$LEGACY_RR" ]; then
      ARTIFACT_REQUESTED=1
      ARTIFACT="$LEGACY_RR"
    fi
  fi
fi

# ---------- 1. Run the 65-item checklist ----------
VIOLATIONS=()
CHECKED=0
PASSED=0
CHECKLIST_STATUS=0

# item_check <id> <category> <description> <boolean-result>
# boolean-result: "pass" or "fail".
item_check() {
  local id="$1" cat="$2" desc="$3" result="$4"
  CHECKED=$((CHECKED + 1))
  if [ "$result" = "pass" ]; then
    printf '  [PASS] %s [category: %s] %s\n' "$id" "$cat" "$desc" >&2
    PASSED=$((PASSED + 1))
  else
    printf '  [FAIL] %s [category: %s] %s\n' "$id" "$cat" "$desc" >&2
    VIOLATIONS+=("$id [category: $cat] — $desc")
  fi
}

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# file_exists <file>
file_exists() {
  [ -f "$1" ] && echo "pass" || echo "fail"
}

# heading_present <file> <heading-regex>
# Pass when an H2 heading matching the pattern exists (case-insensitive).
heading_present() {
  local f="$1" text="$2"
  if grep -Eiq "^##[[:space:]]+${text}([[:space:]]|\$|[[:punct:]])" "$f" 2>/dev/null; then
    echo "pass"
  else
    echo "fail"
  fi
}

# pattern_present <file> <extended-regex>
pattern_present() {
  local f="$1" pattern="$2"
  grep -Eiq "$pattern" "$f" 2>/dev/null && echo "pass" || echo "fail"
}

# cascades_all_resolved <file>
# AC-EC10: scan the "## Pending Cascades" table (if present). Pass when
# every table row's "Resolved" column is populated (not empty, not "-",
# not "no"). Fail when the section exists AND at least one row has an
# empty/unresolved Resolved column.
cascades_all_resolved() {
  local f="$1"
  # Extract the Pending Cascades section. If the section is absent we
  # still pass (the check is about unresolved rows — no section means
  # nothing to resolve).
  awk '
    /^##[[:space:]]+Pending[[:space:]]+Cascades/ { in_sec = 1; next }
    in_sec && /^##[[:space:]]+/ { in_sec = 0 }
    in_sec { print }
  ' "$f" 2>/dev/null |
  awk -F '|' '
    # Only consider table rows that start with "|" and are not
    # separator rows ("---" cells) or header rows (look for "Resolved"
    # in header to find column index).
    /^\|/ && !/^\|[[:space:]]*-/ {
      if (!header_seen) {
        for (i = 1; i <= NF; i++) {
          cell = $i
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
          if (tolower(cell) == "resolved") { resolved_col = i }
        }
        if (resolved_col > 0) { header_seen = 1 }
        next
      }
      if (resolved_col > 0) {
        cell = $resolved_col
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
        if (cell == "" || cell == "-" || tolower(cell) == "no") {
          bad = 1
          exit
        }
      }
    }
    END { if (bad) { print "fail" } else { print "pass" } }
  '
}

# yaml_field_present <file> <field-name>
# Pass when the YAML frontmatter (the first "---" fenced block) contains
# a top-level "<field>: ..." line.
yaml_field_present() {
  local f="$1" field="$2"
  awk -v field="$field" '
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm = 0; exit }
    in_fm {
      if (match($0, "^[[:space:]]*" field "[[:space:]]*:")) {
        print "pass"; hit = 1; exit
      }
    }
    END { if (!hit) print "fail" }
  ' "$f"
}

# prd_referenced_file_exists <file> <canonical-rel-path>
# Pass when the readiness report does NOT reference the given path, OR
# when it DOES reference the path AND that path exists on disk.
# AF-2026-05-21-25: canonical-first lookup — the readiness report may
# reference EITHER `.gaia/artifacts/...` (canonical, ADR-111) or
# `docs/...` (legacy). The regex matches either by treating the trailing
# segment (e.g., `planning-artifacts/prd.md`) as the substring to grep.
# Filesystem existence check: canonical first, then legacy fallback.
prd_referenced_file_exists() {
  local f="$1" canonical_rel="$2"
  # Derive the bare path suffix from the canonical input — strip the
  # canonical .gaia/artifacts/ prefix if present, then build both forms.
  local suffix="${canonical_rel#.gaia/artifacts/}"
  local legacy_rel="docs/$suffix"
  # Pass if NEITHER layout is referenced
  if ! grep -Eq "($canonical_rel|$legacy_rel)" "$f" 2>/dev/null; then
    echo "pass"  # not referenced -> nothing to check
    return
  fi
  # Referenced — check canonical first, then legacy fallback
  if [ -f "$PROJECT_ROOT/$canonical_rel" ] || [ -f "$PROJECT_ROOT/$legacy_rel" ]; then
    echo "pass"
  else
    echo "fail"
  fi
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  # AC4 / AC-EC3 — Caller explicitly pointed at an artifact path but
  # it does not exist on disk or is empty (0 bytes).
  log "no readiness report to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no readiness report to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-readiness-check to produce .gaia/artifacts/planning-artifacts/readiness-report.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 65-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-readiness-check (65 items — 25 script-verifiable, 40 LLM-checkable)\n' >&2

  # --- Script-verifiable items (25) ---

  # -- Artifact Presence category (SV-01..SV-05, 5 items) --
  printf '\n[category: artifact presence]\n' >&2
  item_check "SV-01" "artifact presence" "Readiness report artifact exists" \
    "$(file_exists "$ARTIFACT")"
  item_check "SV-02" "artifact presence" "Readiness report artifact is non-empty" \
    "$(file_nonempty "$ARTIFACT")"
  item_check "SV-03" "artifact presence" "Referenced PRD file exists on disk (if referenced)" \
    "$(prd_referenced_file_exists "$ARTIFACT" ".gaia/artifacts/planning-artifacts/prd.md")"
  item_check "SV-04" "artifact presence" "Referenced architecture file exists on disk (if referenced)" \
    "$(prd_referenced_file_exists "$ARTIFACT" ".gaia/artifacts/planning-artifacts/architecture.md")"
  item_check "SV-05" "artifact presence" "Referenced test-plan file exists on disk (if referenced)" \
    "$(prd_referenced_file_exists "$ARTIFACT" ".gaia/artifacts/test-artifacts/test-plan.md")"

  # -- Cross-Artifact Coherence structural checks (SV-06..SV-08, 3 items) --
  printf '\n[category: cross-artifact coherence]\n' >&2
  item_check "SV-06" "cross-artifact coherence" "Completeness section present (## Completeness heading)" \
    "$(heading_present "$ARTIFACT" "Completeness")"
  item_check "SV-07" "cross-artifact coherence" "Consistency section present (## Consistency heading)" \
    "$(heading_present "$ARTIFACT" "Consistency")"
  item_check "SV-08" "cross-artifact coherence" "Cross-Artifact Contradictions section present" \
    "$(heading_present "$ARTIFACT" "(Cross-Artifact[[:space:]]+)?Contradictions")"

  # -- Cascade Resolution (SV-09..SV-11, 3 items) --
  printf '\n[category: cascade resolution]\n' >&2
  item_check "SV-09" "cascade resolution" "Pending Cascades section present if cascades tracked" \
    "$(pattern_present "$ARTIFACT" '(Pending[[:space:]]+Cascades|contradiction_check)')"
  item_check "SV-10" "cascade resolution" "All Pending Cascades rows have Resolved column populated" \
    "$(cascades_all_resolved "$ARTIFACT")"
  item_check "SV-11" "cascade resolution" "Contradictions table present in report body" \
    "$(pattern_present "$ARTIFACT" '(contradiction_id|contradiction_check|Contradictions[[:space:]]+Table|BLOCKING|WARNING)')"

  # -- Traceability (SV-12..SV-14, 3 items) --
  printf '\n[category: traceability]\n' >&2
  item_check "SV-12" "traceability" "Traceability matrix referenced (traceability-matrix.md mentioned)" \
    "$(pattern_present "$ARTIFACT" 'traceability-matrix\.md|traceability_complete')"
  item_check "SV-13" "traceability" "Traceability complete field present in YAML frontmatter" \
    "$(yaml_field_present "$ARTIFACT" "traceability_complete")"
  item_check "SV-14" "traceability" "Test implementation rate recorded" \
    "$(pattern_present "$ARTIFACT" '(test_implementation_rate|implementation[[:space:]]+rate|test[[:space:]]+plan)')"

  # -- Sizing & Velocity (SV-15..SV-17, 3 items) --
  printf '\n[category: sizing]\n' >&2
  item_check "SV-15" "sizing" "TEA Readiness section present (## TEA Readiness heading)" \
    "$(heading_present "$ARTIFACT" "TEA[[:space:]]+Readiness")"
  item_check "SV-16" "sizing" "Estimation criteria referenced (points or story sizing mentioned)" \
    "$(pattern_present "$ARTIFACT" '(story[[:space:]]+points|estimation|sizing|oversized)')"
  item_check "SV-17" "sizing" "Architecture ADR review recorded (ADR keyword present)" \
    "$(pattern_present "$ARTIFACT" '(ADR|adversarial)')"

  # -- Gate Verdict (SV-18..SV-25, 8 items) --
  printf '\n[category: gate verdict]\n' >&2
  item_check "SV-18" "gate verdict" "YAML frontmatter present (--- fenced block at top of file)" \
    "$(pattern_present "$ARTIFACT" '^---[[:space:]]*$')"
  item_check "SV-19" "gate verdict" "date field present in YAML frontmatter" \
    "$(yaml_field_present "$ARTIFACT" "date")"
  item_check "SV-20" "gate verdict" "status field present in YAML frontmatter (PASS/FAIL/CONDITIONAL)" \
    "$(yaml_field_present "$ARTIFACT" "status")"
  item_check "SV-21" "gate verdict" "checks_passed aggregate field present in YAML frontmatter" \
    "$(yaml_field_present "$ARTIFACT" "checks_passed")"
  item_check "SV-22" "gate verdict" "critical_blockers count field present in YAML frontmatter" \
    "$(yaml_field_present "$ARTIFACT" "critical_blockers")"
  item_check "SV-23" "gate verdict" "contradictions_found count field present in YAML frontmatter" \
    "$(yaml_field_present "$ARTIFACT" "contradictions_found")"
  item_check "SV-24" "gate verdict" "PASS/FAIL verdict emitted in report body or frontmatter" \
    "$(pattern_present "$ARTIFACT" '\b(PASS|FAIL|CONDITIONAL[[:space:]]+PASS)\b')"
  item_check "SV-25" "gate verdict" "Output Verification section present (## Output Verification heading or equivalent)" \
    "$(pattern_present "$ARTIFACT" '(Output[[:space:]]+Verification|readiness-report\.md|Final[[:space:]]+Summary)')"

  # --- LLM-checkable items (40) ---
  printf '\n[LLM-CHECK] The following 40 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  [category: artifact presence]
  LLM-01 — UX design exists and is complete (when declared)
  LLM-02 — Epics/stories artifact is complete with AC on every story
  LLM-03 — Threat model artifact is complete (when declared)
  LLM-04 — Infrastructure design artifact is complete (when declared)
  LLM-05 — Traceability matrix covers every PRD requirement (deep)

  [category: cross-artifact coherence]
  LLM-06 — Every PRD functional requirement is covered by at least one story
  LLM-07 — Every PRD NFR has at least one test case
  LLM-08 — Architecture components cover every functional area in the PRD
  LLM-09 — Every ADR is referenced by at least one component
  LLM-10 — Every epic contains at least one story
  LLM-11 — Every high-risk story carries ATDD coverage
  LLM-12 — prd.md contains a "Review Findings Incorporated" section with substantive content
  LLM-13 — architecture.md contains a "Review Findings Incorporated" section with substantive content
  LLM-14 — Terminology is consistent across PRD, architecture, and test-plan
  LLM-15 — Story component references resolve to architecture component inventory

  [category: cascade resolution]
  LLM-16 — Architecture vs threat model — security requirements aligned (when threat-model.md exists)
  LLM-17 — Architecture vs infrastructure design — topology aligned (when infrastructure-design.md exists)
  LLM-18 — PRD NFR targets vs architecture design decisions — coherent
  LLM-19 — Auth strategy aligned across PRD, architecture, and threat model
  LLM-20 — Critical/high security requirements covered by story ACs (when threat-model.md exists)
  LLM-21 — All BLOCKING contradictions listed in blocking_issues
  LLM-22 — Every recorded contradiction has authority_agent assigned and recommended_resolution populated
  LLM-23 — No unresolved edit-propagation rows outstanding in the Pending Cascades table

  [category: traceability]
  LLM-24 — Orphan requirements flagged (FRs/NFRs with no story coverage)
  LLM-25 — Orphan test cases flagged (tests with no FR/NFR anchor)
  LLM-26 — Test implementation rate meets the gate threshold declared in traceability-matrix.md
  LLM-27 — CI enforced quality gates (not advisory-only) confirmed in ci-setup.md

  [category: sizing]
  LLM-28 — All stories use numeric points (not just T-shirt sizes)
  LLM-29 — No oversized stories (>13 pts) without a split plan recorded
  LLM-30 — All ADRs resolved (none left in "Proposed" state)
  LLM-31 — Adversarial findings incorporated into architecture
  LLM-32 — Acceptance criteria are testable (every AC has a verifiable condition)
  LLM-33 — NFR targets are quantified (thresholds, units)
  LLM-34 — Epic totals reconcile to sprint capacity / velocity data

  [category: gate verdict]
  LLM-35 — Security requirements documented in PRD are sufficient for the declared stack
  LLM-36 — Compliance timeline estimated when GDPR/PCI-DSS/HIPAA applies
  LLM-37 — Rollback procedure documented and feasible for the declared topology
  LLM-38 — Observability stack (logging, metrics, alerting) defined end-to-end
  LLM-39 — Release strategy defined and infrastructure supports it (canary/blue-green/rolling)
  LLM-40 — Overall readiness verdict narrative is well-reasoned given the category-level verdicts
EOF

  TOTAL_ITEMS=65
  LLM_ITEMS=40
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the readiness-report artifact to satisfy the failed items, then rerun /gaia-readiness-check.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no readiness-report artifact found (READINESS_ARTIFACT unset and no readiness-report.md at .gaia/artifacts/planning-artifacts/ or docs/planning-artifacts/) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 12 >/dev/null 2>&1; then
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
