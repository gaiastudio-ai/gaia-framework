#!/usr/bin/env bash
# finalize.sh — /gaia-create-ux skill finalize (E28-S43 + E42-S7)
#
# E42-S7 extends the original Cluster 5 finalize scaffolding with a
# 26-item post-completion checklist (18 script-verifiable + 8
# LLM-checkable) derived from the V1 /gaia-create-ux (create-ux-design)
# checklist. See docs/implementation-artifacts/E42-S7-* for the
# V1 -> V2 mapping.
#
# Responsibilities (per brief §Cluster 5 + story E42-S7):
#   1. Run the script-verifiable subset of the 26 V1 checklist items
#      against the UX design artifact. Validation runs FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S6 contract; story AC5).
#
# Exit codes:
#   0 — finalize succeeded; all 18 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 5 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC4 "output file not found" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   UX_DESIGN_ARTIFACT  Absolute path to the UX design artifact to
#                       validate. When set, the script runs the 26-item
#                       checklist against it. When set but the file does
#                       not exist, AC4 fires — a single "no artifact to
#                       validate" violation is emitted and the script
#                       exits non-zero. When unset, the script looks for
#                       docs/planning-artifacts/ux-design.md relative to
#                       the current working directory. If neither is
#                       present, the checklist run is skipped (classic
#                       Cluster 5 behaviour — observability still runs,
#                       exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-create-ux/finalize.sh"
WORKFLOW_NAME="create-ux"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path ----------
# UX_DESIGN_ARTIFACT wins when set (test fixtures + explicit invocation).
# If it is set but the file is missing, AC4 fires. If unset, fall back
# to docs/planning-artifacts/ux-design.md. If neither is present the
# checklist is simply skipped (observability still runs).
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${UX_DESIGN_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$UX_DESIGN_ARTIFACT"
else
  # ADR-111 smart-fallback: .gaia/artifacts/ first, legacy docs/ second.
  if [ -f ".gaia/artifacts/planning-artifacts/ux-design.md" ]; then
    ARTIFACT=".gaia/artifacts/planning-artifacts/ux-design.md"
  elif [ -f "docs/planning-artifacts/ux-design.md" ]; then
    ARTIFACT="docs/planning-artifacts/ux-design.md"
  fi
fi

# ---------- 1. Run the 26-item checklist ----------
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
# (case-insensitive; trailing content tolerated) is present.
heading_present() {
  local f="$1" text="$2"
  if grep -Ei "^##[[:space:]]+${text}([[:space:]]|\$|[[:punct:]])" "$f" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# section_body_nonempty <file> <heading-regex>
# Pass when the H2 section exists AND has at least one non-blank,
# non-comment content line before the next H2 heading.
section_body_nonempty() {
  local f="$1" pattern="$2"
  awk -v pat="$pattern" '
    BEGIN { in_section = 0; found = 0 }
    {
      if ($0 ~ "^##[[:space:]]+" pat "([[:space:]]|$|[[:punct:]])") {
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

# fr_screen_table_present <file>
# Pass when an "FR-to-Screen Mapping" H2 heading exists AND is followed
# by a markdown table header+separator before the next H2.
fr_screen_table_present() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; saw_header = 0; saw_sep = 0 }
    {
      if ($0 ~ /^##[[:space:]]+FR-to-Screen[[:space:]]+Mapping([[:space:]]|$|[[:punct:]])/) {
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

# fr_screen_table_has_rows <file>
# Pass when the FR-to-Screen Mapping table has at least one data row
# after the separator.
fr_screen_table_has_rows() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; saw_sep = 0; rows = 0 }
    {
      if ($0 ~ /^##[[:space:]]+FR-to-Screen[[:space:]]+Mapping([[:space:]]|$|[[:punct:]])/) {
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

# fr_id_present <file>  -- at least one "FR-###" identifier (traceability).
fr_id_present() {
  grep -Eq 'FR-[0-9]{3,}' "$1" && echo "pass" || echo "fail"
}

# Section-body helpers — bind the heading pattern for each required body
personas_body_nonempty()           { section_body_nonempty "$1" "[Pp]ersonas"; }
ia_body_nonempty()                 { section_body_nonempty "$1" "[Ii]nformation[[:space:]]+[Aa]rchitecture"; }
wireframes_body_nonempty()         { section_body_nonempty "$1" "[Ww]ireframes"; }
interaction_body_nonempty()        { section_body_nonempty "$1" "[Ii]nteraction[[:space:]]+[Pp]atterns"; }
accessibility_body_nonempty()      { section_body_nonempty "$1" "[Aa]ccessibility"; }

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && [ ! -f "$ARTIFACT" ]; then
  # AC4 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk.
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-create-ux to produce docs/planning-artifacts/ux-design.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  log "running 26-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-create-ux (26 items — 18 script-verifiable, 8 LLM-checkable)\n' >&2

  # --- Script-verifiable items (18) ---

  # Envelope (SV-01..SV-03)
  item_check "SV-01" "Output file exists at docs/planning-artifacts/ux-design.md" \
    "$([ -f "$ARTIFACT" ] && echo pass || echo fail)"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  if head -n 20 "$ARTIFACT" | grep -Eq '^(# |---)'; then
    item_check "SV-03" "Artifact has frontmatter or top-level title" pass
  else
    item_check "SV-03" "Artifact has frontmatter or top-level title" fail
  fi

  # Required sections (SV-04..SV-10)
  item_check "SV-04" "Personas section present" \
    "$(heading_present "$ARTIFACT" "Personas")"
  item_check "SV-05" "Information Architecture section present (sitemap)" \
    "$(heading_present "$ARTIFACT" "Information Architecture")"
  item_check "SV-06" "Wireframes section present" \
    "$(heading_present "$ARTIFACT" "Wireframes")"
  item_check "SV-07" "Interaction Patterns section present" \
    "$(heading_present "$ARTIFACT" "Interaction Patterns")"
  item_check "SV-08" "Accessibility section present" \
    "$(heading_present "$ARTIFACT" "Accessibility")"
  item_check "SV-09" "Components section present" \
    "$(heading_present "$ARTIFACT" "Components")"
  item_check "SV-10" "FR-to-Screen Mapping section present" \
    "$(heading_present "$ARTIFACT" "FR-to-Screen Mapping")"

  # Section-body sanity (SV-11..SV-15) — V1 verbatim anchor strings where
  # applicable. SV-13 is the VCP-CHK-14 anchor ("Key screens described").
  item_check "SV-11" "Personas refined with scenarios" \
    "$(personas_body_nonempty "$ARTIFACT")"
  item_check "SV-12" "Sitemap defined" \
    "$(ia_body_nonempty "$ARTIFACT")"
  item_check "SV-13" "Key screens described" \
    "$(wireframes_body_nonempty "$ARTIFACT")"
  item_check "SV-14" "Common UI patterns documented" \
    "$(interaction_body_nonempty "$ARTIFACT")"
  item_check "SV-15" "WCAG compliance target stated" \
    "$(accessibility_body_nonempty "$ARTIFACT")"

  # FR-to-Screen Mapping structural (SV-16..SV-17)
  item_check "SV-16" "FR-to-Screen Mapping table present with markdown table structure" \
    "$(fr_screen_table_present "$ARTIFACT")"
  item_check "SV-17" "FR-to-Screen Mapping table has at least one data row" \
    "$(fr_screen_table_has_rows "$ARTIFACT")"

  # Traceability (SV-18)
  item_check "SV-18" "At least one FR-### identifier referenced (traceability)" \
    "$(fr_id_present "$ARTIFACT")"

  # --- LLM-checkable items (8) ---
  printf '\n[LLM-CHECK] The following 8 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Personas coherent with scenarios, goals, and tech proficiency
  LLM-02 — Every PRD FR maps to at least one page or screen in the sitemap
  LLM-03 — Navigation structure clear (sitemap groupings are plausible)
  LLM-04 — Layout and component placement defined for every key wireframe
  LLM-05 — Form behaviors specified and error states defined across interaction patterns
  LLM-06 — Keyboard navigation planned and screen reader support addressed
  LLM-07 — Each PRD user journey has a corresponding interaction flow
  LLM-08 — Component descriptions specific enough for implementation (not vague)
EOF

  TOTAL_ITEMS=26
  LLM_ITEMS=8
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the UX design artifact to satisfy the failed items, then rerun /gaia-create-ux.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no UX design artifact found (UX_DESIGN_ARTIFACT unset and no docs/planning-artifacts/ux-design.md) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 11 >/dev/null 2>&1; then
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
