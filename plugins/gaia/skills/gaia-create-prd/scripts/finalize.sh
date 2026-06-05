#!/usr/bin/env bash
# finalize.sh — /gaia-create-prd skill finalize
#
# Extends the finalize scaffolding with a 36-item post-completion checklist
# (24 script-verifiable + 12 LLM-checkable) derived from the V1
# /gaia-create-prd checklist plus the product-brief 36-item expansion.
#
# Responsibilities:
#   1. Run the script-verifiable subset of the 36 V1 checklist items
#      against the PRD artifact. Validation runs FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write.
#
# Exit codes:
#   0 — finalize succeeded; all 24 script-verifiable items PASS (or
#       no artifact was requested).
#   1 — one or more script-verifiable checklist items FAIL; the
#       "output file not found" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   PRD_ARTIFACT  Absolute path to the PRD artifact to validate.
#                 When set, the script runs the 36-item checklist
#                 against it. When set but the file does not exist,
#                 a "no artifact to validate" violation is emitted and
#                 the script exits non-zero.
#                 When unset, the script falls back to a canonical-first
#                 path resolution: prefer
#                 .gaia/artifacts/planning-artifacts/prd.md (canonical);
#                 use docs/planning-artifacts/prd.md only on
#                 positive legacy evidence (legacy file exists AND
#                 canonical dir does not). If neither is present, the
#                 checklist run is skipped (observability still runs,
#                 exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-create-prd/finalize.sh"
WORKFLOW_NAME="create-prd"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path (three-tier idiom) ----------
# Tier 1 — env-var override: PRD_ARTIFACT wins when set (test fixtures +
#          explicit invocation). If it is set but the file is missing,
#          the missing-artifact violation fires.
# Tier 2 — positive legacy evidence: legacy file exists AND canonical
#          dir does NOT exist → use legacy docs/planning-artifacts/prd.md.
# Tier 3 — canonical default: greenfield projects route to
#          .gaia/artifacts/planning-artifacts/prd.md.
# If neither file is present the checklist is simply skipped (observability
# still runs).
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${PRD_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$PRD_ARTIFACT"
elif [ -f "docs/planning-artifacts/prd.md" ] && [ ! -d ".gaia/artifacts/planning-artifacts" ]; then
  ARTIFACT="docs/planning-artifacts/prd.md"
elif [ -f ".gaia/artifacts/planning-artifacts/prd.md" ]; then
  ARTIFACT=".gaia/artifacts/planning-artifacts/prd.md"
fi

# ---------- 1. Run the 36-item checklist ----------
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

# heading_present <file> <heading-text>
# Pass when an H2 heading whose body begins with the given text
# (case-insensitive; trailing content tolerated; optional numeric outline
# prefix like "1. ", "10. ", "1.2 " also tolerated) is present.
# The framework's own prd-template.md uses numeric outline prefixes
# (`## 1. Overview`, `## 2. Goals and Non-Goals`, etc.) so the regex MUST
# accept the prefix or the template fails its own checklist.
# heading_present() is a single shared implementation
# (plugins/gaia/scripts/lib/heading-present.sh) with one uniform, permissive
# regex accepting optional numbered+lettered outline prefixes (11, 11b,
# 1.2.3). Previously finalize.sh scripts carried divergent inline copies,
# so the same heading passed one skill's check and failed another's.
# Sourced via a $0-relative path so it works whether or not this script
# defines PLUGIN_SCRIPTS_DIR.
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

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# section_body_nonempty <file> <heading-regex>
# Pass when the H2 section exists AND has at least one non-blank,
# non-comment content line before the next H2 heading.
section_body_nonempty() {
  local f="$1" pattern="$2"
  # Also tolerate a leading numeric outline prefix
  # (`## 9. Out of Scope`, `## 10.1 Constraints`) the way heading_present
  # already does. The framework's own prd-template.md uses numbered
  # outlines, so section body checks failed against valid template-conformant
  # PRDs before this fix.
  awk -v pat="$pattern" '
    BEGIN { in_section = 0; found = 0 }
    {
      if ($0 ~ "^##[[:space:]]+([0-9]+(\\.[0-9]+)*\\.?[[:space:]]+)?" pat "([[:space:]]|$|[[:punct:]])") {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (length(line) > 0 && line !~ /^<!--/) { found = 1 }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# summary_table_present <file>
# Pass when a "Requirements Summary" (optionally "Requirements Summary
# Table") H2 heading exists AND is followed by a markdown table
# header+separator before the next H2.
summary_table_present() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; saw_header = 0; saw_sep = 0 }
    {
      if ($0 ~ /^##[[:space:]]+([0-9]+(\.[0-9]+)*\.?[[:space:]]+)?[Rr]equirements[[:space:]]+[Ss]ummary([[:space:]]+[Tt]able)?([[:space:]]|$|[[:punct:]])/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        if ($0 ~ /^\|.*\|[[:space:]]*$/) { saw_header = 1 }
        if (saw_header && $0 ~ /^\|[[:space:]]*:?-+/) { saw_sep = 1 }
      }
    }
    END { exit ((saw_header && saw_sep) ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# summary_table_has_rows <file>
# Pass when the Requirements Summary table has at least one data row
# after the separator.
summary_table_has_rows() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; saw_sep = 0; rows = 0 }
    {
      if ($0 ~ /^##[[:space:]]+([0-9]+(\.[0-9]+)*\.?[[:space:]]+)?[Rr]equirements[[:space:]]+[Ss]ummary([[:space:]]+[Tt]able)?([[:space:]]|$|[[:punct:]])/) {
        in_section = 1; saw_sep = 0; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        if ($0 ~ /^\|[[:space:]]*:?-+/) { saw_sep = 1; next }
        if (saw_sep && $0 ~ /^\|.*\|/) { rows++ }
      }
    }
    END { exit (rows >= 1 ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# fr_id_present <file>  -- at least one "FR-###" identifier.
fr_id_present() {
  grep -Eq 'FR-[0-9]{3,}' "$1" && echo "pass" || echo "fail"
}

# nfr_id_present <file>  -- at least one "NFR-###" identifier.
nfr_id_present() {
  grep -Eq 'NFR-[0-9]{3,}' "$1" && echo "pass" || echo "fail"
}

# deps_failure_modes_defined <file>
# Pass when the Dependencies section documents BOTH failure-mode text
# AND fallback-behavior text (case-insensitive, hyphen-flexible).
# Accepts EITHER prose form (`failure mode` / `fallback behavior`) OR
# table-column form (`Failure mode` / `Fallback` column header in a
# markdown table row).
deps_failure_modes_defined() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; has_fail = 0; has_fallback = 0 }
    {
      if ($0 ~ /^##[[:space:]]+([0-9]+(\.[0-9]+)*\.?[[:space:]]+)?[Dd]ependencies([[:space:]]|$|[[:punct:]])/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        lower = tolower($0)
        # Prose forms (original behavior).
        if (lower ~ /failure[- ]mode/) { has_fail = 1 }
        if (lower ~ /fallback[- ]behav/) { has_fallback = 1 }
        # Table-header form — a markdown table row containing a Fallback
        # or Failure(-mode) column header counts as documenting it.
        if ($0 ~ /\|/) {
          if (lower ~ /\|[[:space:]]*failure([[:space:]]+mode)?[[:space:]]*\|/) { has_fail = 1 }
          if (lower ~ /\|[[:space:]]*fallback([[:space:]]+behav[a-z]*)?[[:space:]]*\|/) { has_fallback = 1 }
        }
      }
    }
    END { exit ((has_fail && has_fallback) ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# out_of_scope_body_nonempty <file>
out_of_scope_body_nonempty() {
  section_body_nonempty "$1" "[Oo]ut[[:space:]]+of[[:space:]]+[Ss]cope"
}

# constraints_body_nonempty <file>
constraints_body_nonempty() {
  section_body_nonempty "$1" "[Cc]onstraints([[:space:]]+and[[:space:]]+[Aa]ssumptions)?"
}

# success_criteria_body_nonempty <file>
success_criteria_body_nonempty() {
  section_body_nonempty "$1" "[Ss]uccess[[:space:]]+[Cc]riteria"
}

# user_journeys_body_nonempty <file>
user_journeys_body_nonempty() {
  section_body_nonempty "$1" "[Uu]ser[[:space:]]+[Jj]ourneys"
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && [ ! -f "$ARTIFACT" ]; then
  # Caller explicitly pointed at an artifact path but it does not exist
  # on disk.
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-create-prd to produce .gaia/artifacts/planning-artifacts/prd.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  # ---------- 1a. Deterministic Review Findings auto-append ----------
  # The PM subagent reliably omits the "## Review Findings Incorporated"
  # section, but /gaia-create-arch's setup.sh halts when the PRD lacks
  # it — a circular failure with no LLM-side fix. The adversarial-skip
  # note is therefore a deterministic post-step write (script appends it)
  # rather than relying on LLM behavior.
  #
  # This block runs BEFORE the checklist. It appends a minimal default
  # "Adversarial review not triggered" stub ONLY if the section is
  # entirely absent. If a real "## Review Findings Incorporated" section
  # exists (e.g., authored by Step 14 after adversarial review fired),
  # this is a no-op.
  if ! grep -qE '^##[[:space:]]+Review[[:space:]]+Findings[[:space:]]+Incorporated' "$ARTIFACT"; then
    cat >> "$ARTIFACT" <<'AUTO_APPEND'

## Review Findings Incorporated

Adversarial review not triggered — change type: feature.

> Auto-appended by `gaia-create-prd/scripts/finalize.sh`. If the change type was not "feature" or an adversarial review WAS performed, this stub will be overwritten by Step 14's authored content on re-run.
AUTO_APPEND
    log "auto-appended Review Findings Incorporated section (F-4 mitigation)"
  fi

  log "running 36-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-create-prd (36 items — 24 script-verifiable, 12 LLM-checkable)\n' >&2

  # --- Script-verifiable items (24) ---

  # Envelope (SV-01..SV-03)
  item_check "SV-01" "Output artifact exists at resolved path ($ARTIFACT)" \
    "$([ -f "$ARTIFACT" ] && echo pass || echo fail)"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  if head -n 20 "$ARTIFACT" | grep -Eq '^(# |---)'; then
    item_check "SV-03" "Artifact has frontmatter or top-level title" pass
  else
    item_check "SV-03" "Artifact has frontmatter or top-level title" fail
  fi

  # Required sections (SV-04..SV-15)
  item_check "SV-04" "Overview section present" \
    "$(heading_present "$ARTIFACT" "Overview")"
  item_check "SV-05" "Goals and Non-Goals section present" \
    "$(heading_present "$ARTIFACT" "Goals")"
  item_check "SV-06" "User Stories section present" \
    "$(heading_present "$ARTIFACT" "User Stories")"
  item_check "SV-07" "Functional Requirements section present" \
    "$(heading_present "$ARTIFACT" "Functional Requirements")"
  item_check "SV-08" "Non-Functional Requirements section present" \
    "$(heading_present "$ARTIFACT" "Non-Functional Requirements")"
  item_check "SV-09" "User Journeys section present" \
    "$(heading_present "$ARTIFACT" "User Journeys")"
  item_check "SV-10" "Data Requirements section present" \
    "$(heading_present "$ARTIFACT" "Data Requirements")"
  item_check "SV-11" "Integration Requirements section present" \
    "$(heading_present "$ARTIFACT" "Integration Requirements")"
  item_check "SV-12" "Out of Scope section present" \
    "$(heading_present "$ARTIFACT" "Out of Scope")"
  item_check "SV-13" "Constraints section present" \
    "$(heading_present "$ARTIFACT" "Constraints")"
  item_check "SV-14" "Success Criteria section present" \
    "$(heading_present "$ARTIFACT" "Success Criteria")"
  item_check "SV-15" "Dependencies section present" \
    "$(heading_present "$ARTIFACT" "Dependencies")"

  # Requirements Summary Table (SV-16..SV-17)
  item_check "SV-16" "Requirements Summary Table present with markdown table structure" \
    "$(summary_table_present "$ARTIFACT")"
  item_check "SV-17" "Requirements Summary Table has at least one data row" \
    "$(summary_table_has_rows "$ARTIFACT")"

  # Requirement ID conventions (SV-18..SV-19)
  item_check "SV-18" "At least one FR-### functional-requirement identifier present" \
    "$(fr_id_present "$ARTIFACT")"
  item_check "SV-19" "At least one NFR-### non-functional-requirement identifier present" \
    "$(nfr_id_present "$ARTIFACT")"

  # Critical dependencies: failure modes and fallback behavior (SV-20)
  item_check "SV-20" "Critical dependencies have failure modes and fallback behavior defined" \
    "$(deps_failure_modes_defined "$ARTIFACT")"

  # Section body sanity checks (SV-21..SV-24) — guard against empty section bodies
  item_check "SV-21" "Out of Scope section body non-empty" \
    "$(out_of_scope_body_nonempty "$ARTIFACT")"
  item_check "SV-22" "Constraints section body non-empty" \
    "$(constraints_body_nonempty "$ARTIFACT")"
  item_check "SV-23" "Success Criteria section body non-empty" \
    "$(success_criteria_body_nonempty "$ARTIFACT")"
  item_check "SV-24" "User Journeys section body non-empty" \
    "$(user_journeys_body_nonempty "$ARTIFACT")"

  # --- LLM-checkable items (12) ---
  printf '\n[LLM-CHECK] The following 12 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Requirements trace to user needs (user-focus traceability)
  LLM-02 — User stories use the standard "As a... I want... so that..." format
  LLM-03 — Each functional requirement has testable acceptance criteria
  LLM-04 — Acceptance criteria are measurable and unambiguous
  LLM-05 — MoSCoW (or equivalent) prioritisation applied to features
  LLM-06 — No contradictions between requirements
  LLM-07 — Terminology used consistently throughout the PRD
  LLM-08 — User journeys are meaningful and cover happy + error paths
  LLM-09 — Non-functional requirements have measurable targets (thresholds, not vague qualifiers)
  LLM-10 — Constraints are coherent and compatible with the proposed solution
  LLM-11 — Dependency failure modes are articulated with realistic SLAs
  LLM-12 — Scope boundaries are defensible against feature creep
EOF

  TOTAL_ITEMS=36
  LLM_ITEMS=12
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the PRD artifact to satisfy the failed items, then rerun /gaia-create-prd.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no PRD artifact found (PRD_ARTIFACT unset and no prd.md at .gaia/artifacts/planning-artifacts/ or docs/planning-artifacts/) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 13 >/dev/null 2>&1; then
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

# ---------- 4. Auto-save session memory ----------
# Phase 1-3 skills auto-save a session summary to the agent sidecar via
# the shared lib helper. Phase 4 skills (e.g. /gaia-dev-story) short-
# circuit to a no-op so the interactive prompt is preserved. Failure is
# non-blocking — the auto-save helper itself logs warnings to stderr but
# never affects this script's exit code. SKILL_NAME is resolved from the
# parent directory name so the wire-in is identical across all Phase 1-3
# finalize.sh files.
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
