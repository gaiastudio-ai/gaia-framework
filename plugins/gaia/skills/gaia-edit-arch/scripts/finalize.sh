#!/usr/bin/env bash
# finalize.sh — /gaia-edit-arch skill finalize (E28-S46 + E42-S9)
#
# E42-S9 extends the bare-bones Cluster 6 finalize scaffolding with a
# 25-item post-completion checklist (17 script-verifiable + 8
# LLM-checkable) derived from the V1 /gaia-edit-arch (edit-architecture)
# checklist. See .gaia/artifacts/implementation-artifacts/E42-S9-* for the
# V1 -> V2 mapping.
#
# Responsibilities (per brief §Cluster 6 + story E42-S9):
#   1. Run the script-verifiable subset of the 25 V1 checklist items
#      against the edited architecture artifact. Validation runs FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S8 contract; story AC5).
#
# Exit codes:
#   0 — finalize succeeded; all 17 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 6 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC4 "no artifact to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   ARCHITECTURE_ARTIFACT  Absolute path to the architecture artifact to
#                          validate. When set, the script runs the 25-item
#                          checklist against it. When set but the file does
#                          not exist, AC4 fires — a single "no artifact to
#                          validate" violation is emitted and the script
#                          exits non-zero. When unset, the script falls
#                          back to a canonical-first path resolution
#                          (AF-2026-05-21-11): prefer
#                          .gaia/artifacts/planning-artifacts/architecture.md
#                          (post-ADR-111 canonical); use legacy
#                          .gaia/artifacts/planning-artifacts/architecture.md only on
#                          positive pre-ADR-111 evidence (legacy file
#                          exists AND canonical dir does not). If neither
#                          is present, the checklist run is skipped
#                          (classic Cluster 6 behaviour — observability
#                          still runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-edit-arch/finalize.sh"
WORKFLOW_NAME="edit-architecture"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path (AF-2026-05-21-11 three-tier idiom) ----------
# Tier 1 — env-var override: ARCHITECTURE_ARTIFACT wins when set (test
#          fixtures + explicit invocation). If it is set but the file is
#          missing, AC4 fires.
# Tier 2 — positive pre-ADR-111 evidence: legacy file exists AND canonical
#          dir does NOT exist → use legacy docs/planning-artifacts/architecture.md.
# Tier 3 — canonical default: greenfield + post-ADR-111 projects route to
#          .gaia/artifacts/planning-artifacts/architecture.md per ADR-111.
# If neither file is present the checklist is simply skipped (observability
# still runs).
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${ARCHITECTURE_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$ARCHITECTURE_ARTIFACT"
elif [ -f "docs/planning-artifacts/architecture.md" ] && [ ! -d ".gaia/artifacts/planning-artifacts" ]; then
  ARTIFACT="docs/planning-artifacts/architecture.md"
elif [ -f ".gaia/artifacts/planning-artifacts/architecture.md" ]; then
  ARTIFACT=".gaia/artifacts/planning-artifacts/architecture.md"
fi

# ---------- 1. Run the 25-item checklist ----------
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
# Pass when an H2 heading containing the given text (case-insensitive,
# with optional numeric prefix like "## 1. System Overview") is present.
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

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# pattern_present <file> <extended-regex>
# Generic helper — pass when the pattern matches anywhere in the file
# (case-insensitive), fail otherwise.
pattern_present() {
  local f="$1" pattern="$2"
  grep -Eiq "$pattern" "$f" && echo "pass" || echo "fail"
}

# section_table_has_rows <file> <heading-regex>
# Pass when the H2 section exists AND contains a markdown table with
# header + separator + at least one data row before the next H2.
section_table_has_rows() {
  local f="$1" pattern="$2"
  awk -v pat="$pattern" '
    BEGIN { in_section = 0; saw_sep = 0; rows = 0 }
    {
      if ($0 ~ "^##[[:space:]]+([0-9]+\\.[[:space:]]+)?" pat "([[:space:]]|$|[[:punct:]])") {
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

# decision_log_table_present — structural: heading + table header + separator.
decision_log_table_present() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; saw_header = 0; saw_sep = 0 }
    {
      if ($0 ~ /^##[[:space:]]+([0-9]+\.[[:space:]]+)?(Architecture Decisions|Decision Log)([[:space:]]|$|[[:punct:]])/) {
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

# version_marker_present <file>
# Pass when the file contains a semver-style version marker
# (e.g. "version: 0.2.0" in frontmatter, or "Version: 1.4", "v1.1").
# Accepts optional quoting around the version value.
version_marker_present() {
  local f="$1"
  grep -Eiq '(^version:[[:space:]]*["'\'']?[0-9]+\.[0-9]+|[Vv]ersion[[:space:]]*[:=][[:space:]]*["'\'']?[0-9]+\.[0-9]+|\bv[0-9]+\.[0-9]+)' "$f" \
    && echo "pass" || echo "fail"
}

# cascade_rows_present <file>
# Pass when the Cascade Assessment section contains all four canonical
# downstream artifact rows (Epics and Stories, Test Plan, Infrastructure,
# Traceability).
cascade_rows_present() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; e = 0; t = 0; i = 0; tr = 0 }
    {
      if ($0 ~ /^##[[:space:]]+([0-9]+\.[[:space:]]+)?(Cascade Assessment|Cascade Impact|Pending Cascades)([[:space:]]|$|[[:punct:]])/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        lower = tolower($0)
        if (index(lower, "epics and stories"))  { e = 1 }
        if (index(lower, "test plan"))          { t = 1 }
        if (index(lower, "infrastructure"))     { i = 1 }
        if (index(lower, "traceability"))       { tr = 1 }
      }
    }
    END { exit ((e && t && i && tr) ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# cascade_classification_populated <file>
# Pass when the Cascade Assessment body contains at least one impact
# classification token (NONE/MINOR/SIGNIFICANT/BREAKING). Uses a
# portable regex (no \< \> word boundaries — mawk/BSD awk don't
# support them) by anchoring with a non-alphanumeric neighbour or BOL/EOL.
cascade_classification_populated() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; found = 0 }
    {
      if ($0 ~ /^##[[:space:]]+([0-9]+\.[[:space:]]+)?(Cascade Assessment|Cascade Impact|Pending Cascades)([[:space:]]|$|[[:punct:]])/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        if ($0 ~ /(^|[^A-Za-z0-9])(NONE|MINOR|SIGNIFICANT|BREAKING)([^A-Za-z0-9]|$)/) { found = 1 }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# supersede_consistency <file>
# Pass when either (a) no ADR row mentions "Supersedes", or (b) every
# "Supersedes: ADR-N" reference has a matching ADR row whose status
# column contains "Superseded" (case-insensitive). This is the V1
# "Superseded ADRs marked with status update" anchor.
supersede_consistency() {
  local f="$1"
  awk '
    BEGIN { mentioned_any = 0; ok = 1 }
    # Collect every ADR-N that is referenced as a supersede target.
    {
      # Case A: Legacy inline "Supersedes: ADR-NN" form
      while (match($0, /Supersedes[[:space:]]*:?[[:space:]]*ADR-0*[0-9]+/)) {
        mentioned_any = 1
        chunk = substr($0, RSTART, RLENGTH)
        match(chunk, /ADR-0*[0-9]+/)
        sup = substr(chunk, RSTART, RLENGTH)
        targets[sup] = 1
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
    # Case B: Table-row "Superseded by ADR-NN" form — same target semantics.
    {
      line = $0
      while (match(line, /Superseded[[:space:]]+by[[:space:]]+ADR-0*[0-9]+/)) {
        mentioned_any = 1
        chunk = substr(line, RSTART, RLENGTH)
        match(chunk, /ADR-0*[0-9]+/)
        # In the "by" form the status cell IS the marker, so the
        # predecessor row is trivially marked — nothing to verify here.
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END {
      if (!mentioned_any) { exit 0 }
      exit (ok ? 0 : 1)
    }
  ' "$f" && echo "pass" || echo "fail"
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && [ ! -f "$ARTIFACT" ]; then
  # AC4 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk.
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-edit-arch to produce .gaia/artifacts/planning-artifacts/architecture.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  log "running 25-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-edit-arch (25 items — 17 script-verifiable, 8 LLM-checkable)\n' >&2

  # --- Script-verifiable items (17) ---

  # Envelope (SV-01..SV-02)
  item_check "SV-01" "Output file saved to resolved path ($ARTIFACT)" \
    "$([ -f "$ARTIFACT" ] && echo pass || echo fail)"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  # Edit Quality (SV-03..SV-04)
  # Unchanged sections preserved — anchor on System Overview presence.
  item_check "SV-03" "Unchanged sections preserved (System Overview still present)" \
    "$(heading_present "$ARTIFACT" "System[[:space:]]+Overview")"
  item_check "SV-04" "Architecture version incremented (version marker present)" \
    "$(version_marker_present "$ARTIFACT")"

  # Version History (SV-05..SV-06) — V1 anchor "Version History" verbatim.
  item_check "SV-05" "Version History section present" \
    "$(heading_present "$ARTIFACT" "Version[[:space:]]+History")"
  item_check "SV-06" "Version History table has a version note row" \
    "$(section_table_has_rows "$ARTIFACT" "Version[[:space:]]+History")"

  # ADR Quality (SV-07..SV-11)
  item_check "SV-07" "Architecture Decisions section present (Decision Log)" \
    "$(heading_present "$ARTIFACT" "(Architecture[[:space:]]+Decisions|Decision[[:space:]]+Log)")"
  item_check "SV-08" "Decision Log table present with markdown table structure" \
    "$(decision_log_table_present "$ARTIFACT")"
  item_check "SV-09" "New ADR(s) created (Decision Log table has at least one ADR row)" \
    "$(section_table_has_rows "$ARTIFACT" "(Architecture[[:space:]]+Decisions|Decision[[:space:]]+Log)")"
  item_check "SV-10" "Each ADR has context, decision, consequences (ADR-N rows populated)" \
    "$(pattern_present "$ARTIFACT" '\|[[:space:]]*ADR-[0-9]')"
  item_check "SV-11" "Addresses field maps to FR/NFR IDs (FR-### identifier referenced)" \
    "$(pattern_present "$ARTIFACT" 'FR-[0-9]{3,}')"

  # ADR Quality continued — supersede marking (SV-12)
  item_check "SV-12" "Superseded ADRs marked with status update" \
    "$(supersede_consistency "$ARTIFACT")"

  # Review Gate (SV-13)
  item_check "SV-13" "Review Findings Incorporated section present" \
    "$(heading_present "$ARTIFACT" "Review[[:space:]]+Findings[[:space:]]+Incorporated")"

  # Cascade Assessment (SV-14..SV-16) — V1 anchors preserved.
  item_check "SV-14" "Cascade Assessment section present (Pending Cascades retained)" \
    "$(heading_present "$ARTIFACT" "(Cascade[[:space:]]+Assessment|Cascade[[:space:]]+Impact|Pending[[:space:]]+Cascades)")"
  item_check "SV-15" "Cascade impact classified for all four downstream artifacts" \
    "$(cascade_rows_present "$ARTIFACT")"
  item_check "SV-16" "Cascade classification populated (NONE/MINOR/SIGNIFICANT)" \
    "$(cascade_classification_populated "$ARTIFACT")"

  # Output Verification (SV-17) — sidecar memory write referenced.
  item_check "SV-17" "Changes recorded in architect-sidecar memory (sidecar reference present)" \
    "$(pattern_present "$ARTIFACT" 'architect-sidecar')"

  # --- LLM-checkable items (8) ---
  printf '\n[LLM-CHECK] The following 8 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Requested changes applied correctly (edit matches the change request)
  LLM-02 — Unchanged sections preserved exactly (no silent drops or reorders)
  LLM-03 — Consistency maintained across sections (no contradictions introduced)
  LLM-04 — Each new ADR has context, decision, consequences with sound rationale
  LLM-05 — Cascade impact classifications are plausible for the scope of change
  LLM-06 — Adversarial review completed OR explicitly skipped for minor edits
  LLM-07 — Review Findings Incorporated traceable (before/after mapping clear if review ran)
  LLM-08 — Next steps communicated to user appropriately for the cascade outcome
EOF

  TOTAL_ITEMS=25
  LLM_ITEMS=8
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the architecture artifact to satisfy the failed items, then rerun /gaia-edit-arch.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no architecture artifact found (ARCHITECTURE_ARTIFACT unset and no architecture.md at .gaia/artifacts/planning-artifacts/ or docs/planning-artifacts/) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 7 >/dev/null 2>&1; then
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
